// Optionals and error unions: coercions, try, catch, ??, narrowing, .value/.none/.err
use super::*;

impl Checker {
    /// whether v converts to `to` by the error rules. Into E!T: an error of set E (of any set when E is
    /// `error`), a value that coerces to T, or an E2!T when E is `error`. Into `error`: any error value
    pub fn error_coercible(&self, v: &Val, to: TyId) -> bool {
        match self.t.get(to) {
            Ty::ErrUnion(e, t) => {
                if let Ty::ErrUnion(e2, t2) = self.t.get(v.ty) {
                    return t2 == t && *e == ANYERR && self.is_error_ty(*e2);
                }
                (self.is_error_ty(v.ty) && (v.ty == *e || *e == ANYERR)) || (*t != VOID && self.coercible(v, *t))
            }
            Ty::AnyErr => self.is_error_ty(v.ty),
            _ => false,
        }
    }

    /// the conversion error_coercible allows: an error goes in .err, a payload in .v, and another error
    /// union's error is re-coded as an `error` code
    pub fn error_coerce(&mut self, v: Val, to: TyId, span: Span) -> Res<Val> {
        let tc = self.cty(to);
        match self.t.get(to).clone() {
            Ty::ErrUnion(e, t) => {
                if let Ty::ErrUnion(_, _) = self.t.get(v.ty) {
                    let vc = self.cty(v.ty);
                    let code = self.eu_code(v.ty, "_e");
                    let val = if t == VOID { String::new() } else { ", .v = _e.v".into() };
                    return Ok(Val::new(to, format!("({{ {vc} _e = {}; ({tc}){{ .err = {code}{val} }}; }})", v.c)));
                }
                if self.is_error_ty(v.ty) && (v.ty == e || e == ANYERR) {
                    let conv = if v.ty == e { v.c.clone() } else { self.err_code(v.ty, &v.c) };
                    return Ok(Val { pure: v.pure, ..Val::new(to, format!("(({tc}){{ .err = {conv} }})")) });
                }
                let inner = self.coerce(v, t, span)?;
                Ok(Val { pure: inner.pure, ..Val::new(to, format!("(({tc}){{ .v = {} }})", inner.c)) })
            }
            Ty::AnyErr => {
                let c = self.err_code(v.ty, &v.c);
                Ok(Val { pure: v.pure, ..Val::new(ANYERR, c) })
            }
            _ => unreachable!(),
        }
    }

    /// `try x`: the payload of x, or on error runs every scope's errdefers and drops and returns the error
    /// (converted to the fn's error set, which must be x's set or `error`)
    pub fn try_expr(&mut self, x: &Expr, span: Span) -> Res<Val> {
        let v = self.expr(x, None)?;
        let v = self.take(v, x.span)?; // the payload comes out, so an owning local moves
        let Ty::ErrUnion(e, t) = self.t.get(v.ty).clone() else {
            return err(x.span, format!("try needs something that can fail (E!T), found {}", self.ty_name(v.ty)));
        };
        let ret = self.cx.ret;
        let Ty::ErrUnion(re, _) = self.t.get(ret).clone() else {
            return err(span, "try only works inside a function that returns an error union (E!T)");
        };
        if e != re && re != ANYERR {
            return err(span, format!("this can fail with {}, but the function returns {} errors", self.ty_name(e), self.ty_name(re)));
        }
        let tmp = self.tmp("t");
        let vc = self.cty(v.ty);
        let rc = self.cty(ret);
        let code = self.eu_code(v.ty, &tmp);
        let conv = if e == re { format!("{tmp}.err") } else { code.clone() };
        let top = self.cx.scopes.len() - 1;
        let defers = self.scope_exit_code(top, 0, true)?;
        let value = if t == VOID { String::new() } else { format!(" {tmp}.v;") };
        let exit = self.fn_exit(Some(format!("(({rc}){{ .err = {conv} }})")), &defers);
        Ok(Val::new(t, format!("({{ {vc} {tmp} = {}; if ({code}) {{ {exit}; }}{value} }})", v.c)))
    }

    /// `x catch |e| handler`: the payload, or the handler's value on error. The handler may leave
    /// (return/break) instead; when x has no payload it must give no value
    pub fn catch_expr(&mut self, x: &Expr, cap: Option<&(String, Span)>, handler: &Expr, span: Span) -> Res<Val> {
        let v = self.expr(x, None)?;
        let v = self.take(v, x.span)?; // the payload comes out, so an owning local moves
        let Ty::ErrUnion(e, t) = self.t.get(v.ty).clone() else {
            return err(x.span, format!("catch needs something that can fail (E!T), found {}", self.ty_name(v.ty)));
        };
        let tmp = self.tmp("t");
        let vc = self.cty(v.ty);
        let code = self.eu_code(v.ty, &tmp);
        let moved_before = self.cx.moved.clone();
        self.cx.scopes.push(Scope::default());
        let r = (|| {
            // the handler owns the error: bound or not, one that needs delete is deleted when the
            // handler ends (or leaves early, through the scope's exits)
            let name = match cap {
                Some((n, _)) => Some(n.as_str()),
                None if self.needs_drop(e)? => Some("@err"),
                None => None,
            };
            let bind = match name {
                Some(n) => {
                    let ec = self.cty(e);
                    let (c, flag) = self.owned_local(n, e, false)?;
                    format!("{};{flag} ", Self::decl(&ec, &c, &format!("{tmp}.err")))
                }
                None => String::new(),
            };
            let h = self.expr(handler, if t == VOID { None } else { Some(t) })?;
            if h.ty == NEVER {
                self.cx.moved = moved_before; // a handler that leaves moves nothing on the path that goes on
            }
            let top = self.cx.scopes.len() - 1;
            Ok(if h.ty == NEVER || t == VOID {
                if h.ty != NEVER && h.ty != VOID {
                    return err(handler.span, "this function gives no value, so catch shouldn't either");
                }
                let exits = if h.ty == NEVER { String::new() } else { self.scope_exit_code(top, top, false)? };
                let value = if t == VOID { String::new() } else { format!(" {tmp}.v;") };
                Val::new(t, format!("({{ {vc} {tmp} = {}; if ({code}) {{ {bind}{}; {exits}}}{value} }})", v.c, h.c))
            } else {
                if h.ty == VOID {
                    return err(handler.span, "catch needs a value here, or a block that leaves (return/break)");
                }
                let h = self.coerce(h, t, handler.span)?;
                let exits = self.scope_exit_code(top, top, false)?;
                let tc = self.cty(t);
                Val::new(t, format!("({{ {vc} {tmp} = {}; {tc} _r; if ({code}) {{ {bind}_r = {}; {exits}}} else _r = {tmp}.v; _r; }})", v.c, h.c))
            })
        })();
        self.cx.scopes.pop();
        let _ = span;
        r
    }

    /// C for (is present, payload) of the optional c. A niche optional is the pointer itself, null for none.
    /// c appears in both, so it should be a place or pure
    pub fn opt_parts(&self, opt: TyId, c: &str) -> (String, String) {
        let Ty::Opt(inner) = self.t.get(opt) else { unreachable!() };
        if self.t.is_niche(*inner) { (format!("(({c}) != 0)"), c.to_string()) } else { (format!("({c}).has"), format!("({c}).v")) }
    }

    /// `a ?? b`: a's payload, or b when a is none or null. b may leave instead (`?? return x`)
    pub fn orelse(&mut self, a: &Expr, b: &Expr, span: Span) -> Res<Val> {
        let av = self.expr(a, None)?;
        let av = self.take(av, a.span)?; // the payload comes out, so an owning optional moves
        if self.t.is_ptr(av.ty) {
            // p ?? x: a T* that isn't null is a T& (void* stays void*)
            let res = match self.t.get(av.ty).clone() {
                Ty::Ptr(inner) => self.t.intern(Ty::Ref(inner)),
                _ => av.ty,
            };
            let moved_before = self.cx.moved.clone();
            let bv = self.expr(b, Some(res))?;
            if bv.ty == NEVER {
                self.cx.moved = moved_before;
            }
            let pc = self.cty(av.ty);
            if bv.ty == NEVER {
                return Ok(Val::new(res, format!("({{ {pc} _o = {}; if (!_o) {{ {}; }} _o; }})", av.c, bv.c)));
            }
            let bv = self.coerce(bv, res, span)?;
            // either one: read-only where either is (lends.rs)
            let mut prov = (av.ro, av.via, av.root.clone());
            Self::merge_prov(&mut prov, &bv);
            let (ro, via, root) = prov;
            return Ok(Val { ro, via, root, ..Val::new(res, format!("({{ {pc} _o = {}; _o ? _o : ({}); }})", av.c, bv.c)) });
        }
        let Ty::Opt(inner) = self.t.get(av.ty).clone() else {
            return err(a.span, format!("?? needs an optional on the left, found {}", self.ty_name(av.ty)));
        };
        let moved_before = self.cx.moved.clone();
        let bv = self.expr(b, Some(inner))?;
        if bv.ty == NEVER {
            self.cx.moved = moved_before; // `?? return x` moves nothing on the path that goes on
        }
        let oc = self.cty(av.ty);
        let (has, val) = self.opt_parts(av.ty, "_o");
        if bv.ty == NEVER {
            return Ok(Val::new(inner, format!("({{ {oc} _o = {}; if (!{has}) {{ {}; }} {val}; }})", av.c, bv.c)));
        }
        let bv = self.coerce(bv, inner, span)?;
        let mut prov = (av.ro, av.via, av.root.clone());
        Self::merge_prov(&mut prov, &bv);
        let (ro, via, root) = prov;
        Ok(Val { ro, via, root, ..Val::new(inner, format!("({{ {oc} _o = {}; {has} ? {val} : ({}); }})", av.c, bv.c)) })
    }

    /// condition of if/while: bool, or an optional (present?). A local optional gets narrowed.
    pub fn cond(&mut self, cond: &Expr) -> Res<(String, Option<(String, Local)>)> {
        let v = self.expr(cond, Some(BOOL))?;
        if self.t.is_ptr(v.ty) {
            // a pointer is true when it isn't null; a local T* narrows to a T& inside
            let narrow = match (self.t.get(v.ty).clone(), Self::place_key(cond)) {
                (Ty::Ptr(inner), Some(key)) if v.lv => {
                    let rt = self.t.intern(Ty::Ref(inner));
                    Some((key, Local { c: v.c.clone(), ty: rt, mutable: v.mutable, orig: Some((v.c.clone(), v.ty)), flag: None, loops: 0, ro: v.ro, via: v.via, root: v.root.clone(), param: false, own: v.own.clone() }))
                }
                _ => None,
            };
            return Ok((format!("(({}) != 0)", v.c), narrow));
        }
        if let Ty::Opt(inner) = self.t.get(v.ty).clone() {
            let (has, val) = self.opt_parts(v.ty, &v.c);
            let narrow = match Self::place_key(cond) {
                Some(key) if v.lv => Some((key, Local { c: val, ty: inner, mutable: v.mutable, orig: Some((v.c.clone(), v.ty)), flag: None, loops: 0, ro: v.ro, via: v.via, root: v.root.clone(), param: false, own: v.own.clone() })),
                _ => None,
            };
            return Ok((has, narrow));
        }
        let v = self.coerce(v, BOOL, cond.span)?;
        Ok((v.c, None))
    }

    /// "x", "x.a.b", "this.next": places that narrowing can name
    pub fn place_key(e: &Expr) -> Option<String> {
        match &e.kind {
            ExprKind::Path(p) if p.is_single() => Some(p.segs[0].name.clone()),
            ExprKind::This => Some("this".into()),
            ExprKind::Field(b, n, None) => Some(format!("{}.{n}", Self::place_key(b)?)),
            _ => None,
        }
    }

    /// .value / .none on optionals, .err / .value on error unions
    pub fn wrapper_field(&mut self, b: &Val, name: &str, span: Span) -> Res<Option<Val>> {
        let loc = self.loc(span);
        let bc = self.cty(b.ty);
        match (self.t.get(b.ty).clone(), name) {
            (Ty::Opt(_), "none") => {
                let (has, _) = self.opt_parts(b.ty, &b.c);
                Ok(Some(Val { pure: b.pure, ..Val::new(BOOL, format!("(!{has})")) }))
            }
            (Ty::Opt(inner), "value") => {
                let chk = |c: &Self, o: &str| {
                    let (has, _) = c.opt_parts(b.ty, o);
                    if c.opts.release { String::new() } else { format!("if (!{has}) volt_panic(\"unwrapped a null value\", \"{loc}\"); ") }
                };
                if b.lv && self.needs_drop(inner)? {
                    // a place: .value names the payload in place (a borrow), so ownership stays put
                    let (_, val) = self.opt_parts(b.ty, "(*_o)");
                    let ic = self.cty(inner);
                    let ck = chk(self, "(*_o)");
                    return Ok(Some(Val { lv: true, mutable: b.mutable, ..Val::new(inner, format!("(*({{ {bc}* _o = &({}); {ck}({ic}*)&{val}; }}))", b.c)) }));
                }
                let (_, val) = self.opt_parts(b.ty, "_o");
                let ck = chk(self, "_o");
                Ok(Some(Val::new(inner, format!("({{ {bc} _o = {}; {ck}{val}; }})", b.c))))
            }
            (Ty::ErrUnion(e, _), "err") if b.lv && self.needs_drop(e)? => {
                // a place: .err is a view of the error where it is (like .value), so ownership stays
                // put and keeping it takes a copy. The view is element 0 of a compound literal array:
                // an lvalue living for the enclosing block, the place read once
                let opt = self.t.intern(Ty::Opt(e));
                let oc = self.cty(opt);
                let code = self.eu_code(b.ty, "(*_x)");
                let some = self.some(Val::pure(e, "_x->err"), opt).c;
                let none = self.none(opt).c;
                let pick = format!("({{ {bc}* _x = &({}); {oc} _r = ({code}) ? {some} : {none}; _r; }})", b.c);
                Ok(Some(Val { lv: true, pure: b.pure, ..Val::new(opt, format!("((({oc}[1]){{ {pick} }})[0])")) }))
            }
            (Ty::ErrUnion(e, t), "err") => {
                let opt = self.t.intern(Ty::Opt(e));
                let oc = self.cty(opt);
                let code = self.eu_code(b.ty, "_x");
                let some = self.some(Val::pure(e, "_x.err"), opt).c;
                let none = self.none(opt).c;
                // a temporary: the error moves out, and a value it held is deleted
                let drop_v = if !b.lv && t != VOID && self.needs_drop(t)? { format!("if (!({code})) {}(&_x.v); ", self.drop_fn(t)?) } else { String::new() };
                Ok(Some(Val::new(opt, format!("({{ {bc} _x = {}; {oc} _r = ({code}) ? {some} : {none}; {drop_v}_r; }})", b.c))))
            }
            (Ty::ErrUnion(_, t), "value") if t != VOID && b.lv && self.needs_drop(t)? => {
                // a place: .value names the payload in place (a borrow), so ownership stays put
                let code = self.eu_code(b.ty, "(*_x)");
                let chk = if self.opts.release { String::new() } else { format!("if ({code}) volt_panic(\"unwrapped an error\", \"{loc}\"); ") };
                let tc = self.cty(t);
                Ok(Some(Val { lv: true, mutable: b.mutable, ..Val::new(t, format!("(*({{ {bc}* _x = &({}); {chk}({tc}*)&_x->v; }}))", b.c)) }))
            }
            (Ty::ErrUnion(_, t), "value") if t != VOID => {
                let code = self.eu_code(b.ty, "_x");
                let chk = if self.opts.release { String::new() } else { format!("if ({code}) volt_panic(\"unwrapped an error\", \"{loc}\"); ") };
                Ok(Some(Val::new(t, format!("({{ {bc} _x = {}; {chk}_x.v; }})", b.c))))
            }
            _ => Ok(None),
        }
    }

    /// enum type that `.NAME` refers to, from the expected type
    pub fn dot_target(&self, want: Option<TyId>) -> Option<TyId> {
        let w = want?;
        match self.t.get(w) {
            Ty::Enum(_) => Some(w),
            Ty::Opt(i) | Ty::ErrUnion(i, _) if self.enum_of(*i).is_some() => Some(*i),
            Ty::ErrUnion(_, t) if self.enum_of(*t).is_some() => Some(*t),
            _ => None,
        }
    }

    /// `.NAME` or `.NAME(args)`: a variant of the enum the context expects
    pub fn dot_variant(&mut self, name: &str, args: Option<&[Expr]>, want: Option<TyId>, span: Span) -> Res<Val> {
        let Some(ty) = self.dot_target(want) else {
            return err(span, format!("can't tell which enum .{name} belongs to; write Enum::{name}"));
        };
        let eid = self.enum_of(ty).unwrap();
        let Some(idx) = self.variant_index(eid, name) else {
            return err(span, format!("{} has no variant {name}", self.ty_name(ty)));
        };
        self.make_variant(ty, idx, args, span)
    }

}
