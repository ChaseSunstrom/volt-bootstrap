// Calls (direct, through fn values, variadic) and the @builtins.
use super::*;

impl Checker {
    // ---------- calls ----------

    /// Mark a fn instance used. The first time, its prototype is emitted and its body queued for
    /// gen_fn (not for an intrinsic, or a fn a linked library defines).
    pub fn use_fn(&mut self, idx: usize) {
        if !self.used.contains(&idx) {
            self.used.insert(idx);
            if self.fns[idx].intrinsic.is_some() {
                return; // provided by the prelude
            }
            self.emit_proto(idx);
            let has_body = matches!(&self.decls[self.fns[idx].decl].item.kind, ItemKind::Fn(f) if f.body.is_some());
            if has_body && self.linkage(idx) != Linkage::External {
                self.queue.push(idx);
            }
        }
    }

    /// `f(args)`: .VARIANT(...), a method call, a named fn (overloads resolved), Type::f() or an enum
    /// variant; any other callee is a value, called through call_value
    pub(super) fn call(&mut self, callee: &Expr, args: &[Expr], want: Option<TyId>, span: Span) -> Res<Val> {
        match &callee.kind {
            ExprKind::DotVariant(n) => return self.dot_variant(n, Some(args), want, span),
            ExprKind::Field(base, name, gargs) => {
                let recv = self.expr(base, None)?;
                return self.method_call(recv, name, gargs.as_deref().unwrap_or(&[]), args, want, span);
            }
            ExprKind::Path(p) if !(p.is_single() && self.lookup_local(&p.segs[0].name).is_some()) => {
                let ns = self.cx.env.ns;
                let found = if p.segs.len() == 1 { self.lookup(ns, &p.segs[0].name) } else { self.lookup_path_ns(ns, p) };
                let explicit = p.segs.last().unwrap().args.clone().unwrap_or_default();
                match found {
                    Some(Found::Decls(ds)) => {
                        let fns: Vec<DeclId> = ds.into_iter().filter(|d| matches!(self.decls[*d].item.kind, ItemKind::Fn(_))).collect();
                        if !fns.is_empty() {
                            return self.resolve_call(p.last(), &fns, None, None, &explicit, args, want, span);
                        }
                    }
                    None => match self.member_path(p)? {
                        Some(generics::Member::Of(ty, member)) => {
                            if let Some(eid) = self.enum_of(ty) {
                                if let Some(idx) = self.variant_index(eid, &member) {
                                    return self.make_variant(ty, idx, Some(args), span);
                                }
                            }
                            return self.static_call(ty, &member, &explicit, args, want, span);
                        }
                        Some(generics::Member::GenericEnum(d, member)) => {
                            let ty = self.infer_enum(d, &member, Some(args), want, span)?;
                            return self.type_member_value(ty, &member, Some(args), span);
                        }
                        None => {}
                    },
                    _ => {}
                }
            }
            _ => {}
        }
        let f = self.expr(callee, None)?;
        self.call_value(f, args, span)
    }

    /// call through a value: a C fn pointer, a fn(...) value (its fn and env) or a closure
    pub fn call_value(&mut self, f: Val, args: &[Expr], span: Span) -> Res<Val> {
        // a generic closure: the arguments' types pick its instance (made the first time)
        let mut given = Vec::new();
        let mut inst = None;
        if let Ty::Closure(c) = self.t.get(f.ty).clone() {
            if self.closures[c as usize].generic.is_some() {
                for (i, a) in args.iter().enumerate() {
                    let want = self.generic_closure_want(c, i);
                    given.push(self.expr(a, want)?);
                }
                let tys: Vec<TyId> = given.iter().map(|v| v.ty).collect();
                inst = Some(self.closure_instance(c, &tys, span)?);
            }
        }
        let mut given = given.into_iter();
        let (ps, ret, va, kind) = match self.t.get(f.ty).clone() {
            Ty::FnPtr(ps, r, va) => (ps, r, va, 0),
            Ty::FnVal(ps, r) => (ps, r, false, 1),
            Ty::Closure(c) => {
                let k = inst.unwrap_or(c) as usize;
                (self.closures[k].params.clone(), self.closures[k].ret, false, 2)
            }
            _ => return err(span, format!("can't call a {}", self.ty_name(f.ty))),
        };
        if args.len() < ps.len() || (!va && args.len() > ps.len()) {
            return err(span, format!("expected {} arguments, found {}", ps.len(), args.len()));
        }
        let fty = f.ty;
        // what the call runs: this closure's body, or what any fn of this type made into a value does
        let callee = match self.t.get(fty).clone() {
            Ty::Closure(c) => Body::Closure(inst.unwrap_or(c)),
            _ => Body::Value(self.value_key(fty)),
        };
        let site = self.open_site(callee, ret);
        let mut vals = vec![f];
        for (i, a) in args.iter().enumerate() {
            vals.push(match ps.get(i) {
                Some(p) => {
                    let v = match given.next() {
                        Some(v) => v,
                        None => self.expr(a, Some(*p))?,
                    };
                    let v = self.take_into(v, *p, a.span)?;
                    if self.reaches(*p) {
                        self.note_arg(callee, i, v.ro, v.via, v.root.as_deref(), a.span, site);
                    }
                    v
                }
                None => {
                    let v = self.expr(a, None)?;
                    self.vararg_val(v, a.span)?
                }
            });
        }
        let pre = self.seq(&mut vals);
        let cs: Vec<String> = vals[1..].iter().map(|v| v.c.clone()).collect();
        let fc = self.cty(fty);
        let call = match kind {
            0 => format!("({})({})", vals[0].c, cs.join(", ")),
            1 => {
                let sep = if cs.is_empty() { "" } else { ", " };
                format!("({{ {fc} _f = {}; _f.fn(_f.env{sep}{}); }})", vals[0].c, cs.join(", "))
            }
            _ => {
                let Ty::Closure(c) = self.t.get(fty).clone() else { unreachable!() };
                let fname = self.closures[inst.unwrap_or(c) as usize].fn_name.clone();
                let sep = if cs.is_empty() { "" } else { ", " };
                if vals[0].lv {
                    format!("{fname}(&({}){sep}{})", vals[0].c, cs.join(", "))
                } else {
                    format!("({{ {fc} _cl = {}; {fname}(&_cl{sep}{}); }})", vals[0].c, cs.join(", "))
                }
            }
        };
        Ok(Self::site_result(Val::new(ret, Self::wrap_pre(&pre, call)), site))
    }

    /// an argument for C varargs: a str literal becomes a cstr, a float narrower than f64 is promoted
    pub fn vararg_val(&mut self, v: Val, span: Span) -> Res<Val> {
        Ok(match self.t.get(v.ty).clone() {
            Ty::Str if v.lit.is_some() => self.coerce(v, CSTR, span)?,
            Ty::Str => return err(span, "C varargs can't take a str; pass a cstr"),
            Ty::Float(b) if b < 64 => Val { c: format!("((double)({}))", v.c), ty: F64, ..v },
            _ => v,
        })
    }

    // ---------- builtins ----------

    /// a generic arg read as a type in the current fn's env
    pub fn garg_type(&mut self, g: &GenericArg) -> Res<TyId> {
        let env = self.cx.env.clone();
        match g {
            GenericArg::Type(t) => self.resolve_type(t, &env),
            GenericArg::Expr(Expr { kind: ExprKind::Path(p), .. }) => {
                let t = Type { kind: TypeKind::Path(p.clone()), span: p.span };
                self.resolve_type(&t, &env)
            }
            GenericArg::Expr(e) => err(e.span, "expected a type"),
        }
    }

    /// a builtin's argument checked as an expression
    pub fn garg_expr(&mut self, g: &GenericArg, want: Option<TyId>) -> Res<Val> {
        let e = Self::garg_value(g)?;
        self.expr(&e, want)
    }

    /// a generic/builtin argument read as a value: names, calls and indexing (a[i]) parse as types first
    pub fn garg_value(g: &GenericArg) -> Res<Expr> {
        match g {
            GenericArg::Expr(e) => Ok(e.clone()),
            GenericArg::Type(t) => Self::type_as_value(t),
        }
    }

    /// the expression a type-shaped arg spells: a name, a[i] or a[..] (which parse as array and slice types)
    pub(super) fn type_as_value(t: &Type) -> Res<Expr> {
        match &t.kind {
            TypeKind::Path(p) => Ok(Expr { kind: ExprKind::Path(p.clone()), span: t.span }),
            TypeKind::Expr(e) => Ok((**e).clone()),
            TypeKind::Array(elem, Some(len)) => Ok(Expr { kind: ExprKind::Index(P::new(Self::type_as_value(elem)?), len.clone()), span: t.span }),
            TypeKind::Slice(elem) => {
                let all = Expr { kind: ExprKind::Range(None, None, false), span: t.span };
                Ok(Expr { kind: ExprKind::Index(P::new(Self::type_as_value(elem)?), P::new(all)), span: t.span })
            }
            _ => err(t.span, "expected a value, found a type"),
        }
    }

    /// The @builtins that generate code: sizeof, alignof, offsetof, cast, write, slice, read, panic.
    /// The compile-time ones (@typeinfo...) are evaluated by comptime instead.
    pub(super) fn builtin(&mut self, name: &str, gargs: &[GenericArg], args: Option<&[GenericArg]>, want: Option<TyId>, span: Span) -> Res<Val> {
        let args = args.unwrap_or(&[]);
        let n_args = |n: usize| if args.len() == n { Ok(()) } else { err(span, format!("@{name} takes {n} argument(s)")) };
        match name {
            "sizeof" | "alignof" => {
                n_args(1)?;
                let t = self.garg_type(&args[0])?;
                let c = self.cty(t);
                Ok(Val::pure(USIZE, format!("((size_t){}({c}))", if name == "sizeof" { "sizeof" } else { "_Alignof" })))
            }
            "offsetof" => {
                n_args(2)?;
                let t = self.garg_type(&args[0])?;
                let f = match &args[1] {
                    GenericArg::Type(Type { kind: TypeKind::Path(p), .. }) | GenericArg::Expr(Expr { kind: ExprKind::Path(p), .. }) if p.is_single() => p.segs[0].name.clone(),
                    _ => return err(span, "@offsetof(T, field) needs a field name"),
                };
                let c = self.cty(t);
                Ok(Val::pure(USIZE, format!("((size_t)__builtin_offsetof({c}, {f}))")))
            }
            "cast" => {
                n_args(1)?;
                let [g] = gargs else { return err(span, "@cast<T>(x) needs one type") };
                let to = self.garg_type(g)?;
                let v = self.garg_expr(&args[0], None)?;
                let c = self.cty(to);
                // scalars convert as values; anything else is reinterpreted byte for byte
                let scalar = |c: &Checker, t: TyId| matches!(c.t.get(t), Ty::Int(_) | Ty::Float(_) | Ty::Bool | Ty::Ref(_) | Ty::Ptr(_) | Ty::VoidPtr | Ty::CStr | Ty::FnPtr(..)) || (matches!(c.t.get(t), Ty::Opt(i) if c.t.is_niche(*i)));
                if scalar(self, v.ty) && scalar(self, to) {
                    Ok(Val { pure: v.pure, ..Val::new(to, format!("(({c})({}))", v.c)) })
                } else {
                    let fc = self.cty(v.ty);
                    Ok(Val::new(to, format!("({{ {fc} _v = {}; *({c}*)&_v; }})", v.c)))
                }
            }
            "write" => {
                // store into memory without deleting what was there (it isn't a value yet)
                n_args(2)?;
                let p = self.garg_expr(&args[0], None)?;
                let (Ty::Ref(t) | Ty::Ptr(t)) = self.t.get(p.ty).clone() else { return err(span, "@write(p, v) needs a T* first") };
                // a store through p, like *p = v (lends.rs)
                let place = Self::through(Val { lv: true, mutable: true, ..Val::new(t, "") }, &p);
                if !place.mutable {
                    return err(span, "can't assign through this; it reaches a val (or a parameter without var)");
                }
                self.note_write(&place);
                let v = self.garg_expr(&args[1], Some(t))?;
                let v = self.take(v, span)?;
                let v = self.coerce(v, t, span)?;
                let tc = self.cty(t);
                Ok(Val::stmt(format!("({{ {tc}* _w = {}; *_w = {}; }})", p.c, v.c)))
            }
            "slice" => {
                // unchecked: a slice over len values starting at ptr
                n_args(2)?;
                let p = self.garg_expr(&args[0], None)?;
                let (Ty::Ref(t) | Ty::Ptr(t)) = self.t.get(p.ty).clone() else { return err(span, "@slice(p, len) needs a T* first") };
                let n = self.garg_expr(&args[1], Some(USIZE))?;
                let n = self.coerce(n, USIZE, span)?;
                let st = self.t.intern(Ty::Slice(t));
                let sc = self.cty(st);
                // the slice points where p does
                Ok(Val { ro: p.ro, via: p.via, root: p.root.clone(), ..Val::new(st, format!("(({sc}){{ .ptr = {}, .len = {} }})", p.c, n.c)) })
            }
            "read" => {
                // move the value out of memory without copying or deleting it (the opposite of @write)
                n_args(1)?;
                let p = self.garg_expr(&args[0], None)?;
                let (Ty::Ref(t) | Ty::Ptr(t)) = self.t.get(p.ty).clone() else { return err(span, "@read(p) needs a T*") };
                // what's read points where *p does
                Ok(Val { ro: p.ro >> 1, via: lends::deeper(p.via, 1), root: p.root.clone(), ..Val::new(t, format!("(*({}))", p.c)) })
            }
            "panic" => {
                n_args(1)?;
                let v = self.garg_expr(&args[0], Some(STR))?;
                let v = self.coerce(v, STR, span)?;
                let loc = self.loc(span);
                Ok(Val::new(NEVER, format!("volt_panic_str({}, \"{loc}\")", v.c)))
            }
            _ => {
                let _ = want;
                err(span, format!("unknown builtin @{name}"))
            }
        }
    }
}
