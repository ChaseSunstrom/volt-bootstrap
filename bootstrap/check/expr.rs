// Expressions: literals, coercion, the expression switch and paths. Operators are in
// operators.rs, places and aggregates in places.rs, calls and builtins in calls.rs.
use super::cty::c_str_lit;
use super::*;

impl Checker {
    /// a fresh C temporary name (_base7), unique within the fn
    pub fn tmp(&mut self, base: &str) -> String {
        self.cx.next_id += 1;
        format!("_{base}{}", self.cx.next_id)
    }

    /// the innermost local called name, not looking past a barrier scope
    pub fn lookup_local(&self, name: &str) -> Option<Local> {
        for s in self.cx.scopes.iter().rev() {
            if let Some(l) = s.vars.get(name) {
                return Some(l.clone());
            }
            if s.barrier {
                break;
            }
        }
        None
    }

    /// Is this a pointer (or pointer-like optional) narrowed to non-null by if/while? The branch
    /// may assign it again (`cur = cur->next`), so the narrowing only holds when it is read.
    pub fn narrow_recheck(&self, l: &Local) -> bool {
        match &l.orig {
            Some((_, oty)) => self.t.is_ptr(*oty) || matches!(self.t.get(*oty), Ty::Opt(i) if self.niche(*i)),
            None => false,
        }
    }

    /// a local as a value. A narrowed pointer re-checks for null on each read in debug builds (a
    /// null one traps like `->` would); release builds don't check, like every raw pointer deref
    pub fn local_val(&mut self, l: &Local, span: Span) -> Val {
        let base = Val { lv: true, mutable: l.mutable, ro: l.ro, via: l.via, root: l.root.clone(), own: l.own.clone(), ..Val::pure(l.ty, l.c.clone()) };
        if self.opts.release || !self.narrow_recheck(l) {
            return base;
        }
        let (pc, loc) = (self.cty(l.ty), self.loc(span));
        // a box (an optional's niche struct) is null when its pointer is
        let null = match self.niche_field(l.ty) {
            Some(f) => format!("!_nq->{f}"),
            None => "!*_nq".into(),
        };
        Val { c: format!("(*({{ {pc}* _nq = &({}); if ({null}) volt_panic(\"null pointer dereference\", \"{loc}\"); _nq; }}))", l.c), ..base }
    }

    /// check e expecting type ty, then convert it (an error if it can't)
    pub fn expr_as(&mut self, e: &Expr, ty: TyId) -> Res<Val> {
        let v = self.expr(e, Some(ty))?;
        self.coerce(v, ty, e.span)
    }

    // ---------- literals ----------

    /// an integer constant as C, cast to its type (a 128-bit one is built from two 64-bit halves)
    pub fn c_int(&mut self, v: i128, ty: TyId) -> String {
        match self.t.get(ty).clone() {
            Ty::Float(_) => format!("(({})({v}.0))", self.cty(ty)),
            Ty::Int(k) => {
                if k.bits() == 128 {
                    let u = v as u128;
                    format!("(({})(((unsigned __int128){}ULL << 64) | {}ULL))", k.c(), (u >> 64) as u64, u as u64)
                } else if v == i64::MIN as i128 {
                    format!("(({})(-9223372036854775807LL - 1))", k.c())
                } else if v < 0 {
                    format!("(({}){v}LL)", k.c())
                } else {
                    format!("(({}){v}ULL)", k.c())
                }
            }
            _ => unreachable!("c_int on {}", self.ty_name(ty)),
        }
    }

    /// a float constant as C (inf and nan through GCC builtins)
    pub(super) fn c_float(&mut self, v: f64, ty: TyId) -> String {
        let text = if v.is_finite() { format!("{v:?}") } else if v.is_nan() { "__builtin_nan(\"\")".into() } else { format!("{}__builtin_inf()", if v < 0.0 { "-" } else { "" }) };
        format!("(({})({text}))", self.cty(ty))
    }

    /// an integer literal: the wanted type if it fits there (or is a float), else the first of i32,
    /// i64, i128 that holds it
    pub fn int_lit(&mut self, v: i128, want: Option<TyId>) -> Val {
        let ty = match want {
            Some(w) if self.t.int_of(w).is_some_and(|k| k.fits(v)) || self.t.is_float(w) => w,
            _ if IntTy::I32.fits(v) => I32,
            _ if IntTy::I64.fits(v) => I64,
            _ => int(IntTy::I128),
        };
        let c = self.c_int(v, ty);
        Val { lit: Some(Lit::Int(v)), ..Val::pure(ty, c) }
    }

    /// a float literal: the wanted float type, else f64
    pub(super) fn float_lit(&mut self, v: f64, want: Option<TyId>) -> Val {
        let ty = match want {
            Some(w) if self.t.is_float(w) => w,
            _ => F64,
        };
        let c = self.c_float(v, ty);
        Val { lit: Some(Lit::Float(v)), ..Val::pure(ty, c) }
    }

    pub fn str_val(&mut self, s: &[u8]) -> Val {
        let c = format!("((volt_str){{ (const uint8_t*){}, {} }})", c_str_lit(s), s.len());
        Val { lit: Some(Lit::Str(s.to_vec())), ..Val::pure(STR, c) }
    }

    // ---------- coercion ----------

    /// a never value (return, break, a panic...) typed as `to`, for a context that expects one
    pub fn never_as(&mut self, v: Val, to: TyId) -> Val {
        if to == VOID || to == NEVER {
            return Val { ty: to, ..v };
        }
        let c = self.cty(to);
        Val::new(to, format!("({{ {}; __builtin_unreachable(); *({c}*)0; }})", v.c))
    }

    /// v wrapped in optional type opt (for a niche optional, like a pointer's, that's v itself)
    pub fn some(&mut self, v: Val, opt: TyId) -> Val {
        let Ty::Opt(inner) = self.t.get(opt).clone() else { unreachable!() };
        if self.niche(inner) {
            return Val { ty: opt, ..v };
        }
        let c = self.cty(opt);
        let pure = v.pure;
        let inner_c = if inner == VOID { String::new() } else { format!(".v = {}, ", v.c) };
        Val { pure, ..Val::new(opt, format!("(({c}){{ {inner_c}.has = true }})")) }
    }

    /// the empty value of optional type opt
    pub fn none(&mut self, opt: TyId) -> Val {
        let Ty::Opt(inner) = self.t.get(opt).clone() else { unreachable!() };
        let c = self.cty(opt);
        if self.t.is_niche(inner) {
            return Val::pure(opt, format!("(({c})0)"));
        }
        if self.niche_field(inner).is_some() {
            return Val::pure(opt, format!("(({c}){{0}})"));
        }
        Val::pure(opt, format!("(({c}){{ .has = false }})"))
    }

    /// can v convert to `to` implicitly (literals allowed to adapt)?
    pub fn coercible(&self, v: &Val, to: TyId) -> bool {
        if v.ty == to || v.ty == NEVER {
            return true;
        }
        match (&v.lit, self.t.get(to)) {
            (Some(Lit::Int(n)), Ty::Int(k)) => return k.fits(*n),
            (Some(Lit::Int(_)), Ty::Float(_)) | (Some(Lit::Float(_)), Ty::Float(_)) => return true,
            (Some(Lit::Str(_)), Ty::CStr) => return true,
            _ => {}
        }
        match (self.t.get(v.ty), self.t.get(to)) {
            (Ty::Int(a), Ty::Int(b)) => a.widens_to(*b),
            (Ty::Float(a), Ty::Float(b)) => a <= b,
            (Ty::Null, Ty::Opt(_) | Ty::Ptr(_) | Ty::VoidPtr) => true,
            (_, Ty::Opt(inner)) => self.coercible(v, *inner),
            (Ty::Ref(_) | Ty::Ptr(_), Ty::VoidPtr) => true,
            (Ty::Ref(a), Ty::Ptr(b)) => a == b,
            (Ty::Array(a, _), Ty::Slice(b)) => a == b && v.lv,
            (Ty::Str, Ty::Slice(b)) => *b == U8,
            (_, Ty::TraitUnion(_)) => self.union_member(to, v.ty).is_some(),
            (Ty::Struct(_), Ty::Ref(t) | Ty::Ptr(t)) => self.box_inner(v.ty) == Some(*t) && v.lv,
            (Ty::Closure(_), Ty::FnVal(ps, r)) => self.closure_sig(v.ty) == Some((ps.clone(), *r)) || self.generic_closure_arity(v.ty) == Some(ps.len()),
            _ => self.error_coercible(v, to),
        }
    }

    /// v converted to type `to` by an implicit conversion (the ones coercible allows), or an error
    pub fn coerce(&mut self, v: Val, to: TyId, span: Span) -> Res<Val> {
        if v.ty == to {
            return Ok(v);
        }
        if v.ty == NEVER {
            return Ok(self.never_as(v, to));
        }
        match (v.lit.clone(), self.t.get(to).clone()) {
            (Some(Lit::Int(n)), Ty::Int(k)) => {
                if !k.fits(n) {
                    return err(span, format!("{n} doesn't fit in {}", k.name()));
                }
                return Ok(self.int_lit(n, Some(to)));
            }
            (Some(Lit::Int(n)), Ty::Float(_)) => return Ok(self.float_lit(n as f64, Some(to))),
            (Some(Lit::Float(f)), Ty::Float(_)) => return Ok(self.float_lit(f, Some(to))),
            (Some(Lit::Str(s)), Ty::CStr) => {
                if s.contains(&0) {
                    return err(span, "this string has a \\0 inside, so it can't be a cstr");
                }
                return Ok(Val { lit: Some(Lit::Str(s.clone())), ..Val::pure(CSTR, c_str_lit(&s)) });
            }
            _ => {}
        }
        let (from_t, to_t) = (self.t.get(v.ty).clone(), self.t.get(to).clone());
        let ok = |ty: TyId, c: String, v: &Val| Ok(Val { ty, c, lv: false, mutable: false, pure: v.pure, lit: None, owner: None, ro: v.ro, via: v.via, rop: false, pvia: None, root: v.root.clone(), own: None });
        match (from_t, to_t) {
            (Ty::Int(a), Ty::Int(b)) if a.widens_to(b) => ok(to, format!("(({})({}))", b.c(), v.c), &v),
            (Ty::Float(a), Ty::Float(b)) if a <= b => {
                let c = self.cty(to);
                ok(to, format!("(({c})({}))", v.c), &v)
            }
            (Ty::Null, Ty::Opt(_)) => Ok(self.none(to)),
            (Ty::Null, Ty::Ptr(_) | Ty::VoidPtr) => {
                let c = self.cty(to);
                Ok(Val::pure(to, format!("(({c})0)")))
            }
            (_, Ty::Opt(inner)) if self.coercible(&v, inner) => {
                let v = self.coerce(v, inner, span)?;
                Ok(self.some(v, to))
            }
            (Ty::Ref(_) | Ty::Ptr(_), Ty::VoidPtr) => ok(to, format!("((void*)({}))", v.c), &v),
            (Ty::Ref(a), Ty::Ptr(b)) if a == b => ok(to, v.c.clone(), &v), // the same C pointer
            (Ty::Array(a, n), Ty::Slice(b)) if a == b => {
                if !v.lv {
                    return err(span, "can't make a slice of a temporary array; store it in a variable first");
                }
                let c = self.cty(to);
                // the slice reaches the array, as &array would
                self.note_mut(&v);
                let (ro, via, root) = Self::addr_prov(&v);
                Ok(Val { ro, via, root, ..ok(to, format!("(({c}){{ ({}).a, {n} }})", v.c), &v)? })
            }
            (Ty::Str, Ty::Slice(b)) if b == U8 => {
                let c = self.cty(to);
                ok(to, format!("({{ volt_str _s = {}; ({c}){{ (uint8_t*)_s.ptr, _s.len }}; }})", v.c), &v)
            }
            (Ty::Closure(id), Ty::FnVal(ps, r)) if self.closure_sig(v.ty) == Some((ps.clone(), r)) || self.generic_closure_arity(v.ty) == Some(ps.len()) => {
                // a closure literal is a C compound literal, which lives to the end of the block
                // ponytail: the fn value can still outlive a stored-away literal; a borrow check would catch it
                if !v.lv && !v.c.starts_with("((volt_closure") {
                    return err(span, "a fn(...) value borrows its closure; store the closure in a variable first");
                }
                // a generic closure: its instance for these parameters
                let mut body = id;
                if self.closure_sig(v.ty).is_none() {
                    body = self.closure_instance(id, &ps, span)?;
                    let ci = &self.closures[body as usize];
                    if ci.params != ps || ci.ret != r {
                        let got = self.t.intern(Ty::FnVal(ci.params.clone(), ci.ret));
                        return err(span, format!("for these parameters this closure is a {}, not a {}", self.ty_name(got), self.ty_name(to)));
                    }
                }
                let c = self.closure_to_fn(&v, to, body)?;
                ok(to, c, &v)
            }
            (Ty::Struct(_), Ty::Ref(t) | Ty::Ptr(t)) if self.box_inner(v.ty) == Some(t) => {
                if !v.lv {
                    return err(span, format!("this {} would be deleted right away; store it in a variable first", self.ty_name(v.ty)));
                }
                let pf = self.owner(v.ty).unwrap().0;
                ok(to, format!("({}).{}", v.c, c_field(&pf)), &v)
            }
            (_, Ty::TraitUnion(_)) if self.union_member(to, v.ty).is_some() => {
                let i = self.union_member(to, v.ty).unwrap();
                let c = self.cty(to);
                Ok(Val { pure: v.pure, ..Val::new(to, format!("(({c}){{ .tag = {i}, .u.m{i} = {} }})", v.c)) })
            }
            _ if self.error_coercible(&v, to) => self.error_coerce(v, to, span),
            _ => Err(Diag::new(span, format!("expected {}, found {}", self.ty_name(to), self.ty_name(v.ty))).type_diff()),
        }
    }

    /// Make impure values temps (left to right) when more than one might have side effects,
    /// since C leaves argument/operand order unspecified. Returns C statements to run first.
    pub fn seq(&mut self, vals: &mut [Val]) -> String {
        let impure = vals.iter().filter(|v| !v.pure && v.ty != VOID && v.ty != NEVER).count();
        if impure < 2 {
            return String::new();
        }
        let mut pre = String::new();
        for v in vals.iter_mut() {
            if !v.pure && v.ty != VOID && v.ty != NEVER {
                let t = self.tmp("s");
                let cty = self.cty(v.ty);
                pre.push_str(&format!("{cty} {t} = {}; ", v.c));
                v.c = t;
                v.pure = true;
            }
        }
        pre
    }

    /// C statements pre, then the expression c, as one expression
    pub fn wrap_pre(pre: &str, c: String) -> String {
        if pre.is_empty() { c } else { format!("({{ {pre}{c}; }})") }
    }

    // ---------- expressions ----------

    /// Check an expression and lower it to C. `want` is the expected type, if known: literals, null
    /// and .VARIANT adapt to it, but callers still coerce the result.
    pub fn expr(&mut self, e: &Expr, want: Option<TyId>) -> Res<Val> {
        let span = e.span;
        // @typeinfo, comptime fn calls and comptime locals are evaluated now, not emitted
        if self.is_ct_expr(e) {
            let v = self.ct_eval(e, want)?;
            return self.ct_to_val(v, want, span);
        }
        match &e.kind {
            ExprKind::Int(v) => {
                if *v > i128::MAX as u128 {
                    return err(span, "number too large");
                }
                Ok(self.int_lit(*v as i128, want))
            }
            ExprKind::Char(v) => {
                let want = want.or(Some(if *v <= 255 { U8 } else { int(IntTy::U32) }));
                Ok(self.int_lit(*v as i128, want))
            }
            ExprKind::Float(v) => Ok(self.float_lit(*v, want)),
            ExprKind::Str(s) => {
                let v = self.str_val(s);
                match want {
                    Some(CSTR) => self.coerce(v, CSTR, span),
                    _ => Ok(v),
                }
            }
            ExprKind::Bool(b) => Ok(Val::pure(BOOL, if *b { "true" } else { "false" })),
            ExprKind::Null => match want {
                Some(w) if matches!(self.t.get(w), Ty::Opt(_)) => Ok(self.none(w)),
                _ => Ok(Val::pure(NULL, "NULL")),
            },
            ExprKind::Path(p) => self.path_expr(p, want, span),
            ExprKind::Unary(op, x) => self.unary(*op, x, want, span),
            ExprKind::Binary(op, a, b) => self.binary(*op, a, b, want, span),
            ExprKind::Assign(op, l, r) => self.assign(*op, l, r, span),
            ExprKind::IncDec(x, inc) => {
                let one = Expr { kind: ExprKind::Int(1), span };
                self.assign(Some(if *inc { BinOp::Add } else { BinOp::Sub }), x, &one, span)
            }
            ExprKind::Cast(x, t) => {
                let env = self.cx.env.clone();
                let to = self.resolve_type(t, &env)?;
                self.cast(x, to, span)
            }
            ExprKind::Field(base, name, gargs) => {
                if gargs.is_some() {
                    return err(span, "generic methods need a call: x.f<T>()");
                }
                // a field narrowed by if/while
                if let Some(l) = Self::place_key(e).and_then(|k| self.lookup_local(&k)) {
                    return Ok(self.local_val(&l, span));
                }
                let b = self.expr(base, None)?;
                self.field(b, name, span)
            }
            ExprKind::Index(base, idx) => self.index(base, idx, span),
            ExprKind::Call(callee, args) => self.call(callee, args, want, span),
            ExprKind::Builtin(name, gargs, args) => self.builtin(name, gargs, args.as_deref(), want, span),
            ExprKind::Tuple(elems) => self.tuple(elems, want, span),
            ExprKind::Literal(entries) => self.literal(entries, want, span),
            ExprKind::Range(lo, hi, incl) => self.range_val(lo.as_deref(), hi.as_deref(), *incl, want, span),
            ExprKind::Return(v) => self.ret(v.as_deref(), span),
            ExprKind::Break(label, v) => self.brk(label.as_deref(), v.as_deref(), span),
            ExprKind::Continue(label) => self.cont(label.as_deref(), span),
            ExprKind::Block(label, b) => self.block_expr(label.as_deref(), b, want, span),
            ExprKind::Loop(label, b) => self.loop_expr(label.as_deref(), b, want, span),
            ExprKind::While(label, cond, b) => self.while_expr(label.as_deref(), cond, b, span),
            ExprKind::For(f) => self.for_expr(f, want, span),
            ExprKind::If { cond, then, els, comptime: true } => {
                // only the branch that's taken gets checked
                let c = self.ct_eval(cond, Some(BOOL))?;
                let taken = match c {
                    comptime::CVal::Bool(b) => b,
                    _ => return err(cond.span, "comptime if needs a bool"),
                };
                if taken {
                    let (code, div) = self.block_code(then)?;
                    Ok(Val::new(if div { NEVER } else { VOID }, code))
                } else if let Some(e) = els {
                    self.expr(e, want)
                } else {
                    Ok(Val::stmt("((void)0)"))
                }
            }
            ExprKind::If { cond, then, els, .. } => self.if_expr(cond, then, els.as_deref(), span),
            ExprKind::Move(x) => {
                let v = self.expr(x, want)?;
                self.take(v, span)
            }
            ExprKind::Copy(x) => {
                let v = self.expr(x, want)?;
                self.copy_val(v, span)
            }
            ExprKind::ErrorAny => Ok(Val::pure(ANYERR, "((uint32_t)1)")),
            ExprKind::This => match self.lookup_local("this") {
                Some(l) => Ok(self.local_val(&l, span)),
                None => err(span, "no 'this' here (static functions don't have one)"),
            },
            ExprKind::DotVariant(n) => self.dot_variant(n, None, want, span),
            ExprKind::Try(x) => self.try_expr(x, span),
            ExprKind::Catch(x, cap, h) => self.catch_expr(x, cap.as_ref(), h, span),
            ExprKind::OrElse(a, b) => self.orelse(a, b, span),
            ExprKind::Match { scrut, arms, comptime: true } => self.ct_match(scrut, arms, want, span),
            ExprKind::Match { scrut, arms, .. } => self.match_expr(scrut, arms, want, span),
            ExprKind::Closure { caps, generics, params, ret, body } => self.closure_expr(caps, generics, params, ret.as_ref(), body, want, span),
            ExprKind::Await(x) => self.await_expr(x, want),
            ExprKind::Async(_) => err(span, "async f() builds a frame in place, so it only works as `val fr = async f()`"),
        }
    }

    /// a name as a value: a local, a generic value param, a global, a fn (a fn value, or a C fn
    /// pointer where one is wanted) or Type::member
    pub(super) fn path_expr(&mut self, p: &Path, want: Option<TyId>, span: Span) -> Res<Val> {
        if p.is_single() {
            let name = &p.segs[0].name;
            if let Some(l) = self.lookup_local(name) {
                if self.narrow_recheck(&l) {
                    return Ok(self.local_val(&l, span));
                }
                if self.cx.moved.contains(&l.c) {
                    let d = Diag::new(span, format!("'{name}' was moved earlier (by move, an assignment, an argument or a return), so it can't be used here"));
                    return Err(match self.cx.move_sites.get(&l.c) {
                        Some(at) => d.label(*at, "moved here"),
                        None => d,
                    });
                }
                let owner = l.flag.as_ref().map(|_| name.clone());
                return Ok(Val { lv: true, mutable: l.mutable, owner, ro: l.ro, via: l.via, root: l.root.clone(), own: l.own.clone(), ..Val::pure(l.ty, l.c) });
            }
            match self.cx.env.generics.iter().rev().find(|(n, _)| n == name).cloned() {
                Some((_, GVal::Int(v))) => return Ok(self.int_lit(v, want)),
                Some((_, GVal::Str(s))) => {
                    let v = self.str_val(&s);
                    return if want == Some(CSTR) { self.coerce(v, CSTR, span) } else { Ok(v) };
                }
                _ => {}
            }
        }
        let ns = self.cx.env.ns;
        let found = if p.segs.len() == 1 { self.lookup(ns, &p.segs[0].name) } else { self.lookup_path_ns(ns, p) };
        match found {
            Some(Found::Decls(ds)) => {
                let d = ds[0];
                self.visible(d, span)?;
                match &self.decls[d].item.clone().kind {
                    ItemKind::Global(_) => {
                        let (c, ty, mutable) = self.global(d, span)?;
                        Ok(Val { lv: true, mutable, ..Val::pure(ty, c) })
                    }
                    ItemKind::Fn(f) => {
                        if ds.len() > 1 {
                            return err(span, format!("'{}' is overloaded, so it can't be used as a value here", f.name));
                        }
                        // f<Args>: that instance (generic args bound as in a call with none to infer from)
                        let binds = match p.segs.last().unwrap().args.clone() {
                            Some(explicit) => {
                                let unknown = vec![None; f.params.iter().filter(|p| p.name != "this").count()];
                                match self.bind_cand(d, None, None, &explicit, &unknown)? {
                                    Ok((b, _)) => b,
                                    Err(m) => return err(span, m),
                                }
                            }
                            None => Vec::new(),
                        };
                        let i = self.fn_inst(d, binds, span)?;
                        self.use_fn(i);
                        let inst = self.fns[i].clone();
                        let ps: Vec<TyId> = inst.params.iter().map(|p| p.ty).collect();
                        // an optional C fn pointer (a C callback param) wants the thin pointer too
                        let want = want.map(|w| match self.t.get(w) {
                            Ty::Opt(i) => *i,
                            _ => w,
                        });
                        if matches!(want.map(|w| self.t.get(w).clone()), Some(Ty::FnPtr(..))) || inst.c_varargs {
                            // extern "C" fn(...): a plain C function pointer
                            let ty = self.t.intern(Ty::FnPtr(ps, inst.ret, inst.c_varargs));
                            self.escape(Body::Fn(i), ty);
                            return Ok(Val::pure(ty, format!("(&{})", inst.c_name)));
                        }
                        let ty = self.t.intern(Ty::FnVal(ps, inst.ret));
                        self.escape(Body::Fn(i), ty);
                        let c = self.fn_value(i, ty);
                        Ok(Val::pure(ty, c))
                    }
                    _ => err(span, format!("'{}' is a type, not a value", p.last())),
                }
            }
            Some(Found::Ns(_)) => err(span, format!("'{}' is a namespace, not a value", p.last())),
            None => match self.member_path(p)? {
                Some(generics::Member::Of(ty, member)) => self.type_member_value(ty, &member, None, span),
                Some(generics::Member::GenericEnum(d, member)) => {
                    let ty = self.infer_enum(d, &member, None, want, span)?;
                    self.type_member_value(ty, &member, None, span)
                }
                None => Err(self.unknown(span, "name", self.cx.env.ns, p, true)),
            },
        }
    }

    /// `Type::member` as a value, or called with args
    pub fn type_member_value(&mut self, ty: TyId, member: &str, args: Option<&[Expr]>, span: Span) -> Res<Val> {
        if let Some(eid) = self.enum_of(ty) {
            if let Some(idx) = self.variant_index(eid, member) {
                return self.make_variant(ty, idx, args, span);
            }
        }
        err(span, format!("{} has no member '{member}'", self.ty_name(ty)))
    }

}
