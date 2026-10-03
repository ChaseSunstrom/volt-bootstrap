// Places (fields, indexing, slicing) and aggregates (tuples, struct literals, ranges).
use super::*;

impl Checker {
    // ---------- places ----------

    /// `b.name`: a struct or tuple field, a slice's or str's len/ptr, an array's len, or an optional's
    /// or error union's own fields (wrapper_field). A reference is seen through.
    pub fn field(&mut self, b: Val, name: &str, span: Span) -> Res<Val> {
        // .value/.none/.err see through a reference, like struct fields
        let b = match self.t.get(b.ty) {
            Ty::Ref(d) if matches!(self.t.get(*d), Ty::Opt(_) | Ty::ErrUnion(..)) => Self::through(Val { lv: true, mutable: true, pure: b.pure, ..Val::new(*d, format!("(*{})", b.c)) }, &b),
            _ => b,
        };
        if let Some(v) = self.wrapper_field(&b, name, span)? {
            return Ok(v);
        }
        let base_ty = match self.t.get(b.ty) {
            Ty::Ref(d) => *d,
            _ => b.ty,
        };
        // an owning pointer (@owns) is used like its T&: names it doesn't have itself go to the T
        let own_field = |c: &mut Self, sid: u32| c.struct_fields(sid, span).map(|fs| fs.iter().any(|f| f.name == name));
        let forward = match (self.owner(base_ty), self.t.get(base_ty).clone()) {
            (Some(o), Ty::Struct(sid)) if !own_field(self, sid)? => Some(o),
            _ => None,
        };
        if let Some((pf, inner)) = forward {
            let access = if base_ty == b.ty { format!("({}).{}", b.c, c_field(&pf)) } else { format!("({})->{}", b.c, c_field(&pf)) };
            let rt = self.t.intern(Ty::Ref(inner));
            return self.field(Val { lv: true, mutable: true, pure: b.pure, ..Val::new(rt, access) }, name, span);
        }
        // a field of a temporary that owns something: copy the field out, then delete the temporary
        if !b.lv && base_ty == b.ty && self.needs_drop(b.ty)? {
            let tc = self.cty(b.ty);
            let d = self.drop_fn(b.ty)?;
            let f = self.field(Val { lv: true, ..Val::pure(b.ty, "_ft") }, name, span)?;
            if self.needs_drop(f.ty)? {
                return err(span, "can't take a field that owns something out of a temporary; store the value in a variable first");
            }
            let fc = self.cty(f.ty);
            return Ok(Val::new(f.ty, format!("({{ {tc} _ft = {}; {fc} _fv = {}; {d}(&_ft); _fv; }})", b.c, f.c)));
        }
        if let Ty::Ptr(_) = self.t.get(b.ty) {
            return err(span, format!("this is a pointer ({}); reach what it points at with ->: p->{name}", self.ty_name(b.ty)));
        }
        // what the struct's references point at: through b, one depth further than b's own
        let (ty, access, lv, mutable, rop, pvia, own, ro, via) = match self.t.get(b.ty).clone() {
            Ty::Ref(inner) => (inner, format!("({})->", b.c), true, b.ro & 1 == 0, b.ro & 1 != 0, b.via, None, b.ro >> 1, lends::deeper(b.via, 1)),
            _ => (b.ty, format!("({}).", b.c), b.lv, b.mutable, b.rop, b.pvia, b.own.clone(), b.ro, b.via),
        };
        let root = b.root.clone();
        // a field is part of the place; what a pointer field points at isn't (a val is shallow), but
        // it points where the struct's references do
        let place = |ty, c: String| Val { lv, mutable, pure: b.pure, rop, pvia, ro, via, root: root.clone(), own: own.clone(), ..Val::new(ty, c) };
        match self.t.get(ty).clone() {
            Ty::Struct(sid) => {
                let fields = self.struct_fields(sid, span)?;
                match fields.iter().find(|f| f.name == name) {
                    // a header struct's array field is a bare C array: view it as Volt's array wrapper (same layout)
                    Some(f) if self.header_struct(sid) && matches!(self.t.get(f.ty), Ty::Array(..)) => {
                        let w = self.cty(f.ty);
                        Ok(place(f.ty, format!("(*({w}*)&{access}{})", c_field(name))))
                    }
                    Some(f) => Ok(place(f.ty, format!("{access}{}", c_field(name)))),
                    None => {
                        let names: Vec<String> = fields.iter().map(|f| f.name.clone()).collect();
                        Err(self.no_field(span, ty, name, &names))
                    }
                }
            }
            Ty::Tuple(ts, names) => {
                let i = name.parse::<usize>().ok().or_else(|| names.iter().position(|n| n.as_deref() == Some(name)));
                match i {
                    Some(i) if i < ts.len() => Ok(place(ts[i], format!("{access}f{i}"))),
                    _ => {
                        let names: Vec<String> = names.iter().flatten().cloned().collect();
                        Err(self.no_field(span, ty, name, &names))
                    }
                }
            }
            Ty::Slice(_) | Ty::Str if name == "len" => Ok(Val { pure: b.pure, ..Val::new(USIZE, format!("{access}len")) }),
            Ty::Slice(t) if name == "ptr" => {
                let r = self.t.intern(Ty::Ptr(t));
                Ok(Val { pure: b.pure, ..Val::new(r, format!("{access}ptr")) })
            }
            Ty::Str if name == "ptr" => {
                let r = self.t.intern(Ty::Ptr(U8));
                Ok(Val { pure: b.pure, ..Val::new(r, format!("((uint8_t*){access}ptr)")) })
            }
            Ty::Array(_, n) if name == "len" => {
                let c = self.c_int(n as i128, USIZE);
                Ok(Val::pure(USIZE, c))
            }
            _ => err(span, format!("{} has no field '{name}'", self.ty_name(ty))),
        }
    }

    /// `b[i]`, bounds-checked in debug builds for arrays, slices and strs (pointers and cstrs aren't);
    /// `b[lo..hi]` is slice_expr
    pub(super) fn index(&mut self, be: &Expr, ie: &Expr, span: Span) -> Res<Val> {
        if let ExprKind::Range(lo, hi, incl) = &ie.kind {
            return self.slice_expr(be, lo.as_deref(), hi.as_deref(), *incl, span);
        }
        let mut b = self.expr(be, None)?;
        if let Ty::Ref(inner) = self.t.get(b.ty).clone() {
            b = Self::through(Val { ty: inner, c: format!("(*({}))", b.c), lv: true, mutable: true, ..b.clone() }, &b);
        }
        let i = self.expr(ie, Some(USIZE))?;
        if self.t.int_of(i.ty).is_none() {
            return err(ie.span, format!("index must be an integer, found {}", self.ty_name(i.ty)));
        }
        if let Ty::Ptr(t) = self.t.get(b.ty).clone() {
            // p[i]: unchecked, like C
            let mut pair = [b, i];
            let pre = self.seq(&mut pair);
            let c = format!("(({})[{}])", pair[0].c, pair[1].c);
            let r = pair[0].clone();
            if !pre.is_empty() {
                let et = self.cty(t);
                return Ok(Self::through(Val { lv: true, mutable: true, ..Val::new(t, format!("(*({{ {pre}({et}*)&{c}; }}))")) }, &r));
            }
            return Ok(Self::through(Val { lv: true, mutable: true, ..Val::new(t, c) }, &r));
        }
        let loc = self.loc(span);
        let check = |len: &str| if self.opts.release { String::new() } else { format!("if (_i >= {len}) volt_bounds(_i, {len}, \"{loc}\"); ") };
        let (elem, c, lv) = match self.t.get(b.ty).clone() {
            Ty::Array(t, n) => {
                let chk = check(&n.to_string());
                let et = self.cty(t);
                if b.lv {
                    (t, format!("(*({{ size_t _i = (size_t)({}); {chk}({et}*)&({}).a[_i]; }}))", i.c, b.c), true)
                } else {
                    let at = self.cty(b.ty);
                    (t, format!("({{ {at} _a = {}; size_t _i = (size_t)({}); {chk}_a.a[_i]; }})", b.c, i.c), false)
                }
            }
            Ty::Slice(t) => {
                let chk = check("_s.len");
                let st = self.cty(b.ty);
                (t, format!("(*({{ {st} _s = {}; size_t _i = (size_t)({}); {chk}&_s.ptr[_i]; }}))", b.c, i.c), true)
            }
            Ty::Str => {
                let chk = check("_s.len");
                (U8, format!("({{ volt_str _s = {}; size_t _i = (size_t)({}); {chk}_s.ptr[_i]; }})", b.c, i.c), false)
            }
            Ty::CStr => (U8, format!("((uint8_t)({})[{}])", b.c, i.c), false),
            _ => return err(span, format!("can't index a {}", self.ty_name(b.ty))),
        };
        // a slice's elements are what it points at; an array's are part of it
        if matches!(self.t.get(b.ty), Ty::Slice(_)) {
            return Ok(Self::through(Val { lv, mutable: lv, ..Val::new(elem, c) }, &b));
        }
        Ok(Val { lv, mutable: lv && b.mutable, rop: b.rop, pvia: b.pvia, ro: b.ro, via: b.via, root: b.root.clone(), own: b.own.clone(), ..Val::new(elem, c) })
    }

    /// `b[lo..hi]` (either end optional): a slice of an array or slice, a str of a str. Debug builds
    /// check lo <= hi <= len.
    pub(super) fn slice_expr(&mut self, be: &Expr, lo: Option<&Expr>, hi: Option<&Expr>, incl: bool, span: Span) -> Res<Val> {
        let mut b = self.expr(be, None)?;
        if let Ty::Ref(inner) = self.t.get(b.ty).clone() {
            b = Self::through(Val { ty: inner, c: format!("(*({}))", b.c), lv: true, mutable: true, ..b.clone() }, &b);
        }
        // the slice reaches the array (as &array would) or what the sliced slice does
        let (sro, svia, sroot) = if matches!(self.t.get(b.ty), Ty::Slice(_)) { (b.ro, b.via, b.root.clone()) } else { Self::addr_prov(&b) };
        self.note_mut(&b);
        let lo = match lo {
            Some(e) => self.expr_as(e, USIZE)?.c,
            None => "0".into(),
        };
        let (elem, base, len, out_ty) = match self.t.get(b.ty).clone() {
            Ty::Array(t, n) => {
                if !b.lv {
                    return err(be.span, "can't slice a temporary array; store it in a variable first");
                }
                let et = self.cty(t);
                (t, format!("(({et}*)({}).a)", b.c), n.to_string(), None)
            }
            Ty::Slice(t) => (t, "_b.ptr".into(), "_b.len".into(), None),
            Ty::Str => (U8, "_b.ptr".into(), "_b.len".into(), Some(STR)),
            _ => return err(span, format!("can't slice a {}", self.ty_name(b.ty))),
        };
        let out = match out_ty {
            Some(t) => t,
            None => self.t.intern(Ty::Slice(elem)),
        };
        let hi = match hi {
            Some(e) => {
                let h = self.expr_as(e, USIZE)?.c;
                if incl { format!("({h}) + 1") } else { h }
            }
            None => len.clone(),
        };
        let bind = if matches!(self.t.get(b.ty), Ty::Array(..)) {
            String::new()
        } else {
            let bt = self.cty(b.ty);
            format!("{bt} _b = {}; ", b.c)
        };
        let chk = if self.opts.release {
            String::new()
        } else {
            let loc = self.loc(span);
            format!("if (_lo > _hi || _hi > {len}) volt_bounds(_hi, {len}, \"{loc}\"); ")
        };
        let oc = self.cty(out);
        Ok(Val { ro: sro, via: svia, root: sroot, ..Val::new(out, format!("({{ {bind}size_t _lo = {lo}, _hi = {hi}; {chk}({oc}){{ {base} + _lo, _hi - _lo }}; }})")) })
    }

    // ---------- aggregates ----------

    /// `(a, b, ...)`: the elements move in; a wanted tuple type of the same length types them
    pub(super) fn tuple(&mut self, elems: &[Expr], want: Option<TyId>, span: Span) -> Res<Val> {
        // a tuple wanted inside an optional or an error union guides the elements too
        let mut want = want;
        while let Some(w) = want {
            match self.t.get(w).clone() {
                Ty::Opt(inner) | Ty::ErrUnion(_, inner) => want = Some(inner),
                _ => break,
            }
        }
        let wants: Vec<Option<TyId>> = match want.map(|w| self.t.get(w).clone()) {
            Some(Ty::Tuple(ts, _)) if ts.len() == elems.len() => ts.into_iter().map(Some).collect(),
            _ => vec![None; elems.len()],
        };
        let mut vals = Vec::new();
        for (e, w) in elems.iter().zip(&wants) {
            let v = self.expr(e, *w)?;
            let v = self.take(v, e.span)?;
            vals.push(match w {
                Some(w) => self.coerce(v, *w, e.span)?,
                None => v,
            });
        }
        if vals.iter().any(|v| v.ty == VOID || v.ty == NULL) {
            return err(span, "tuple elements need a value type");
        }
        let ty = match want {
            Some(w) if matches!(self.t.get(w), Ty::Tuple(ts, _) if ts.len() == elems.len()) => w,
            _ => self.t.intern(Ty::Tuple(vals.iter().map(|v| v.ty).collect(), vec![None; vals.len()])),
        };
        let pre = self.seq(&mut vals);
        let c = self.cty(ty);
        let inits: Vec<String> = vals.iter().enumerate().map(|(i, v)| format!(".f{i} = {}", v.c)).collect();
        let pure = vals.iter().all(|v| v.pure);
        let (ro, via, root) = self.merged_prov(ty, &vals);
        Ok(Val { pure, ro, via, root, ..Val::new(ty, Self::wrap_pre(&pre, format!("(({c}){{ {} }})", inits.join(", ")))) })
    }

    /// A `{ ... }` literal of the wanted type: a struct (fields by name, the rest from their
    /// defaults), an array, a tuple, or one of those inside an optional or error union.
    pub(super) fn literal(&mut self, entries: &[(Option<String>, Expr)], want: Option<TyId>, span: Span) -> Res<Val> {
        let Some(w) = want else { return err(span, "can't tell what type this literal is; give the variable a type") };
        match self.t.get(w).clone() {
            Ty::Opt(inner) => {
                let v = self.literal(entries, Some(inner), span)?;
                Ok(self.some(v, w))
            }
            Ty::ErrUnion(_, inner) => {
                let v = self.literal(entries, Some(inner), span)?;
                self.coerce(v, w, span)
            }
            Ty::Struct(sid) => {
                if entries.len() > 1 && self.union_struct(sid) {
                    return err(span, "a C union's literal sets one member; assign another afterwards");
                }
                let fields = self.struct_fields(sid, span)?;
                let mut given: Vec<Option<Val>> = vec![None; fields.len()];
                for (name, e) in entries {
                    let n = match (name, &e.kind) {
                        (Some(n), _) => n.clone(),
                        (None, ExprKind::Path(p)) if p.is_single() => p.segs[0].name.clone(),
                        _ => return err(e.span, "struct literal entries need names: { field: value }"),
                    };
                    let Some(i) = fields.iter().position(|f| f.name == n) else {
                        let names: Vec<String> = fields.iter().map(|f| f.name.clone()).collect();
                        return Err(self.no_field(e.span, w, &n, &names));
                    };
                    if given[i].is_some() {
                        return err(e.span, format!("field '{n}' is set twice"));
                    }
                    let v = self.expr(e, Some(fields[i].ty))?;
                    given[i] = Some(self.take_into(v, fields[i].ty, e.span)?);
                }
                // in declaration order; what's left out takes its default
                let header = self.header_struct(sid);
                let (mut vals, mut kept) = (Vec::new(), Vec::new());
                for (i, f) in fields.iter().enumerate() {
                    vals.push(match given[i].take() {
                        Some(_) if header && matches!(self.t.get(f.ty), Ty::Array(..)) => {
                            return err(span, format!("C array field '{}' can't be set in a literal; assign it afterwards", f.name));
                        }
                        Some(v) => v,
                        None if header => continue, // like C: what's left out is zero
                        None => self.field_default(sid, f, span)?,
                    });
                    kept.push(f);
                }
                let pre = self.seq(&mut vals);
                let c = self.cty(w);
                let inits: Vec<String> = kept.iter().zip(&vals).filter(|(f, _)| f.ty != VOID).map(|(f, v)| format!(".{} = {}", c_field(&f.name), v.c)).collect();
                let pure = vals.iter().all(|v| v.pure);
                let (ro, via, root) = self.merged_prov(w, &vals);
                Ok(Val { pure, ro, via, root, ..Val::new(w, Self::wrap_pre(&pre, format!("(({c}){{ {} }})", inits.join(", ")))) })
            }
            Ty::Array(t, n) => {
                if entries.is_empty() {
                    return self.zero_value(w, span); // {}: all zero, like a var without an initializer
                }
                if entries.len() as u64 != n {
                    return err(span, format!("expected {n} elements, found {}", entries.len()));
                }
                let mut vals = Vec::new();
                for (name, e) in entries {
                    if name.is_some() {
                        return err(e.span, "array literals don't take names");
                    }
                    let v = self.expr(e, Some(t))?;
                    vals.push(self.take_into(v, t, e.span)?);
                }
                let pre = self.seq(&mut vals);
                let c = self.cty(w);
                let inits: Vec<String> = vals.iter().map(|v| v.c.clone()).collect();
                let pure = vals.iter().all(|v| v.pure);
                let (ro, via, root) = self.merged_prov(w, &vals);
                Ok(Val { pure, ro, via, root, ..Val::new(w, Self::wrap_pre(&pre, format!("(({c}){{ {{ {} }} }})", inits.join(", ")))) })
            }
            Ty::Tuple(..) => {
                let elems: Vec<Expr> = entries.iter().map(|(_, e)| e.clone()).collect();
                self.tuple(&elems, want, span)
            }
            _ => err(span, format!("a {{ }} literal can't make a {}", self.ty_name(w))),
        }
    }

    /// `{ x; n }`: an array of the wanted type (or one inside an optional or error union) holding n
    /// copies of x, which is evaluated once
    pub(super) fn repeat(&mut self, x: &Expr, n: &Expr, want: Option<TyId>, span: Span) -> Res<Val> {
        let Some(w) = want else { return err(span, "can't tell what type this literal is; give the variable a type") };
        let (t, len) = match self.t.get(w).clone() {
            Ty::Opt(inner) => {
                let v = self.repeat(x, n, Some(inner), span)?;
                return Ok(self.some(v, w));
            }
            Ty::ErrUnion(_, inner) => {
                let v = self.repeat(x, n, Some(inner), span)?;
                return self.coerce(v, w, span);
            }
            Ty::Array(t, len) => (t, len),
            _ => return err(span, format!("a {{ x; n }} literal makes an array, not a {}", self.ty_name(w))),
        };
        let env = self.cx.env.clone();
        let Ok(count) = self.const_int(n, &env) else { return err(n.span, "a repeat count must be known at compile time") };
        if count != len as i128 {
            return err(span, format!("this repeats {count} times but the array holds {len}"));
        }
        if self.needs_drop(t)? {
            return err(x.span, format!("can't repeat a {}: it owns memory; build the elements one by one", self.ty_name(t)));
        }
        let v = self.expr(x, Some(t))?;
        let v = self.coerce(v, t, x.span)?;
        let (ro, via, root) = self.merged_prov(w, std::slice::from_ref(&v));
        Ok(Val { ro, via, root, ..self.fill_array(w, t, len, &v.c) })
    }

    /// an array of type `at` (len elements of type t) with every element set to the C value `c`,
    /// evaluated once
    pub fn fill_array(&mut self, at: TyId, t: TyId, len: u64, c: &str) -> Val {
        let (ac, tc) = (self.cty(at), self.cty(t));
        let (r, v) = (self.tmp("r"), self.tmp("v"));
        Val::new(at, format!("({{ {}; {ac} {r}; for (size_t _k = 0; _k < {len}; _k++) {r}.a[_k] = {v}; {r}; }})", Self::decl(&tc, &v, c)))
    }

    /// value for a field left out of a struct literal
    pub fn field_default(&mut self, sid: u32, f: &FieldInfo, span: Span) -> Res<Val> {
        if let Some(d) = &f.default {
            let env = self.structs[sid as usize].env.clone();
            return self.in_env(env, |c| c.expr_as(d, f.ty));
        }
        if matches!(self.t.get(f.ty), Ty::Opt(_)) {
            return Ok(self.none(f.ty));
        }
        if self.t.is_ptr(f.ty) {
            let c = self.cty(f.ty);
            return Ok(Val::pure(f.ty, format!("(({c})0)"))); // a pointer left out is null
        }
        err(span, format!("missing field '{}' (it has no default)", f.name))
    }

    /// check something in another env (callee/struct namespace), with the caller's locals hidden
    pub fn in_env<T>(&mut self, env: Rc<Env>, f: impl FnOnce(&mut Self) -> Res<T>) -> Res<T> {
        let saved = std::mem::replace(&mut self.cx.env, env);
        self.cx.scopes.push(Scope { barrier: true, ..Default::default() });
        let r = f(self);
        self.cx.scopes.pop();
        self.cx.env = saved;
        r
    }

    /// `lo..hi` as a range value (`for (i) in lo..hi` doesn't come here); a constant range wanted as an
    /// array fills the array instead
    pub(super) fn range_val(&mut self, lo: Option<&Expr>, hi: Option<&Expr>, incl: bool, want: Option<TyId>, span: Span) -> Res<Val> {
        let (Some(lo), Some(hi)) = (lo, hi) else { return err(span, "open ranges only work for slicing: a[1..], a[..2]") };
        // a range assigned to an array fills it
        if let Some(w) = want {
            if let Ty::Array(t, n) = self.t.get(w).clone() {
                let env = self.cx.env.clone();
                let (l, h) = (self.const_int(lo, &env)?, self.const_int(hi, &env)?);
                let count = h - l + incl as i128;
                if count != n as i128 {
                    return err(span, format!("this range has {count} values but the array holds {n}"));
                }
                let c = self.cty(w);
                let tc = self.cty(t);
                let first = self.expr_as(lo, t)?;
                return Ok(Val::new(w, format!("({{ {c} _r; for (size_t _k = 0; _k < {n}; _k++) _r.a[_k] = ({tc})({} + _k); _r; }})", first.c)));
            }
        }
        let a = self.expr(lo, None)?;
        let b = self.expr(hi, None)?;
        let (a, b) = self.unify(a, b, span)?;
        if self.t.int_of(a.ty).is_none() {
            return err(span, "ranges need integers");
        }
        // the value keeps an exclusive end; for lo..=MAX it overflows, which traps in debug builds
        let k = self.t.int_of(a.ty).unwrap();
        let hi_c = if incl { self.int_arith(BinOp::Add, k, &b.c, "1", span)? } else { b.c.clone() };
        let ty = self.t.intern(Ty::Range(a.ty));
        let c = self.cty(ty);
        Ok(Val::new(ty, format!("(({c}){{ {}, {hi_c} }})", a.c)))
    }

}
