// Operators: unary, binary (checked integer arithmetic, pointer arithmetic, shifts,
// comparisons), assignment and casts.
use super::*;

impl Checker {
    // ---------- operators ----------

    /// -x, !x, ~x, &x and *x. In debug builds negating an integer traps on overflow and *p checks a raw
    /// pointer for null.
    pub(super) fn unary(&mut self, op: UnOp, x: &Expr, want: Option<TyId>, span: Span) -> Res<Val> {
        match op {
            UnOp::Neg => {
                let v = self.expr(x, want)?;
                match &v.lit {
                    Some(Lit::Int(n)) => return Ok(self.int_lit(-n, want.or(Some(v.ty)))),
                    Some(Lit::Float(f)) => return Ok(self.float_lit(-f, Some(v.ty))),
                    _ => {}
                }
                match self.t.get(v.ty).clone() {
                    Ty::Float(_) => Ok(Val { pure: v.pure, ..Val::new(v.ty, format!("(-({}))", v.c)) }),
                    Ty::Int(k) if k.signed() => {
                        let c = if self.opts.release {
                            format!("(({})(-({})))", k.c(), v.c)
                        } else {
                            let loc = self.loc(span);
                            format!("({{ {} _r; if (__builtin_sub_overflow(({})0, {}, &_r)) volt_panic(\"integer overflow\", \"{loc}\"); _r; }})", k.c(), k.c(), v.c)
                        };
                        Ok(Val::new(v.ty, c))
                    }
                    _ => err(span, format!("can't negate a {}", self.ty_name(v.ty))),
                }
            }
            UnOp::Not => {
                let v = self.expr_as(x, BOOL)?;
                Ok(Val { pure: v.pure, ..Val::new(BOOL, format!("(!({}))", v.c)) })
            }
            UnOp::BitNot => {
                let v = self.expr(x, want)?;
                let Some(k) = self.t.int_of(v.ty) else { return err(span, format!("~ needs an integer, found {}", self.ty_name(v.ty))) };
                Ok(Val { pure: v.pure, ..Val::new(v.ty, format!("(({})~({}))", k.c(), v.c)) })
            }
            UnOp::Addr => {
                let v = self.expr(x, None)?;
                if !v.lv {
                    return err(span, "can't take the address of a temporary value; store it in a variable first");
                }
                let ty = self.t.intern(Ty::Ref(v.ty));
                self.note_mut(&v);
                let (ro, via, root) = Self::addr_prov(&v);
                Ok(Val { pure: v.pure, ro, via, root, ..Val::new(ty, format!("(&({}))", v.c)) })
            }
            UnOp::Deref => {
                let v = self.expr(x, None)?;
                if let Some((pf, inner)) = self.owner(v.ty) {
                    return Ok(Val { lv: true, mutable: true, pure: v.pure, ..Val::new(inner, format!("(*(({}).{}))", v.c, c_field(&pf))) });
                }
                match self.t.get(v.ty).clone() {
                    Ty::Ref(t) => Ok(Self::through(Val { lv: true, mutable: true, pure: v.pure, ..Val::new(t, format!("(*({}))", v.c)) }, &v)),
                    Ty::Ptr(t) => {
                        // a raw pointer may be null: debug builds check, like bounds
                        let c = if self.opts.release {
                            format!("(*({}))", v.c)
                        } else {
                            let (pc, loc) = (self.cty(v.ty), self.loc(span));
                            format!("(*({{ {pc} _np = {}; if (!_np) volt_panic(\"null pointer dereference\", \"{loc}\"); _np; }}))", v.c)
                        };
                        Ok(Self::through(Val { lv: true, mutable: true, pure: v.pure, ..Val::new(t, c) }, &v))
                    }
                    Ty::VoidPtr => err(span, "can't dereference a void*; @cast it to a typed pointer first"),
                    Ty::Opt(_) => err(span, "this pointer might be null; check it with if or ?? first"),
                    _ => err(span, format!("can't dereference a {}", self.ty_name(v.ty))),
                }
            }
        }
    }

    /// Bring two operands to one type: literals adapt, then lossless widening.
    pub(super) fn unify(&mut self, a: Val, b: Val, span: Span) -> Res<(Val, Val)> {
        if a.ty == b.ty {
            return Ok((a, b));
        }
        if a.lit.is_some() && b.lit.is_none() && self.coercible(&a, b.ty) {
            let t = b.ty;
            return Ok((self.coerce(a, t, span)?, b));
        }
        if b.lit.is_some() && self.coercible(&b, a.ty) {
            let t = a.ty;
            return Ok((a, self.coerce(b, t, span)?));
        }
        if self.coercible(&a, b.ty) && !matches!(self.t.get(b.ty), Ty::Opt(_)) {
            let t = b.ty;
            return Ok((self.coerce(a, t, span)?, b));
        }
        if self.coercible(&b, a.ty) && !matches!(self.t.get(a.ty), Ty::Opt(_)) {
            let t = a.ty;
            return Ok((a, self.coerce(b, t, span)?));
        }
        Err(Diag::new(span, format!("mismatched types {} and {}", self.ty_name(a.ty), self.ty_name(b.ty))).type_diff())
    }

    /// Binary operators. The right operand is checked expecting the left's type (so literals adapt),
    /// integer constants fold, and integer arithmetic traps on overflow in debug builds.
    pub(super) fn binary(&mut self, op: BinOp, ae: &Expr, be: &Expr, want: Option<TyId>, span: Span) -> Res<Val> {
        use BinOp::*;
        if matches!(op, And | Or) {
            let a = self.expr_as(ae, BOOL)?;
            let b = self.expr_as(be, BOOL)?;
            let c = format!("(({}) {} ({}))", a.c, if op == And { "&&" } else { "||" }, b.c);
            return Ok(Val { pure: a.pure && b.pure, ..Val::new(BOOL, c) });
        }
        // a numeric expected type guides the operands of arithmetic (a comparison's result says nothing)
        let is_cmp = matches!(op, Eq | Ne | Lt | Gt | Le | Ge);
        let operand_want = if is_cmp { None } else { want.filter(|w| self.t.int_of(*w).is_some() || self.t.is_float(*w)) };
        let a = self.expr(ae, operand_want)?;
        let b_want = if matches!(be.kind, ExprKind::Null) || a.lit.is_some() || a.ty == NULL { operand_want } else { Some(a.ty) };
        let b = self.expr(be, b_want)?;
        if !is_cmp {
            if let Some(v) = self.pointer_arith(op, a.clone(), b.clone(), span)? {
                return Ok(v);
            }
        }
        if matches!(op, Shl | Shr) {
            return self.shift(op, a, b, span);
        }
        // fold constants
        if let (Some(Lit::Int(x)), Some(Lit::Int(y))) = (&a.lit, &b.lit) {
            let (x, y) = (*x, *y);
            let r = match op {
                Add | WAdd => x.checked_add(y),
                Sub | WSub => x.checked_sub(y),
                Mul | WMul => x.checked_mul(y),
                Div => x.checked_div(y),
                Rem => x.checked_rem(y),
                BitAnd => Some(x & y),
                BitOr => Some(x | y),
                BitXor => Some(x ^ y),
                _ => None,
            };
            if let Some(r) = r {
                let t = if a.ty == b.ty { Some(a.ty) } else { want };
                return Ok(self.int_lit(r, want.or(t)));
            }
            if !is_cmp {
                return err(span, "constant overflow or division by zero");
            }
        }
        if is_cmp {
            return self.compare(op, a, b, span);
        }
        let (a, b) = self.unify(a, b, span)?;
        let ty = a.ty;
        let mut pair = [a, b];
        let pre = self.seq(&mut pair);
        let [a, b] = pair;
        let c = match self.t.get(ty).clone() {
            Ty::Int(k) => self.int_arith(op, k, &a.c, &b.c, span)?,
            Ty::Float(_) => {
                let o = match op {
                    Add | WAdd => "+",
                    Sub | WSub => "-",
                    Mul | WMul => "*",
                    Div => "/",
                    Rem => return Ok(Val::new(ty, Self::wrap_pre(&pre, format!("__builtin_fmod({}, {})", a.c, b.c)))),
                    _ => return err(span, format!("{} doesn't work on floats", op.text())),
                };
                format!("(({}) {o} ({}))", a.c, b.c)
            }
            _ => return err(span, format!("can't use {} on {}", op.text(), self.ty_name(ty))),
        };
        Ok(Val { pure: a.pure && b.pure && self.opts.release, ..Val::new(ty, Self::wrap_pre(&pre, c)) })
    }

    /// p + n, p - n (scaled by the element size, like C) and p - q; other arithmetic on pointers is an error
    pub(super) fn pointer_arith(&mut self, op: BinOp, a: Val, b: Val, span: Span) -> Res<Option<Val>> {
        use BinOp::*;
        for t in [a.ty, b.ty] {
            match self.t.get(t) {
                Ty::Ref(_) => return err(span, "can't do arithmetic on a reference (T&); a pointer (T*) can"),
                Ty::VoidPtr => return err(span, "can't do arithmetic on a void*; @cast it to a typed pointer first"),
                _ => {}
            }
        }
        let (ap, bp) = (matches!(self.t.get(a.ty), Ty::Ptr(_)), matches!(self.t.get(b.ty), Ty::Ptr(_)));
        if !ap && !bp {
            return Ok(None);
        }
        if ap && bp && op == Sub {
            if a.ty != b.ty {
                return Err(Diag::new(span, format!("mismatched types {} and {}", self.ty_name(a.ty), self.ty_name(b.ty))).type_diff());
            }
            let mut pair = [a, b];
            let pre = self.seq(&mut pair);
            let c = format!("((ptrdiff_t)(({}) - ({})))", pair[0].c, pair[1].c);
            return Ok(Some(Val::new(int(IntTy::Isize), Self::wrap_pre(&pre, c))));
        }
        if !ap && bp && op == Add {
            return self.pointer_arith(op, b, a, span); // n + p is p + n, like C
        }
        if ap && !bp && matches!(op, Add | Sub) {
            let b = if b.lit.is_some() { self.coerce(b, int(IntTy::Isize), span)? } else { b };
            if self.t.int_of(b.ty).is_none() {
                return err(span, format!("a pointer moves by an integer, found {}", self.ty_name(b.ty)));
            }
            let ty = a.ty;
            let mut pair = [a, b];
            let pre = self.seq(&mut pair);
            let c = format!("(({}) {} ({}))", pair[0].c, if op == Add { "+" } else { "-" }, pair[1].c);
            return Ok(Some(Val::new(ty, Self::wrap_pre(&pre, c))));
        }
        err(span, "pointers only add or subtract an integer (p + n, p - n), or subtract a pointer (p - q)")
    }

    /// An integer operation on C operands a and b. Debug builds trap when +, -, * overflow and when / or
    /// % divides by zero or overflows (MIN / -1); the wrapping ops (+%, -%, *%) compute unsigned.
    pub(super) fn int_arith(&mut self, op: BinOp, k: IntTy, a: &str, b: &str, span: Span) -> Res<String> {
        use BinOp::*;
        let (t, ut) = (k.c(), k.c_unsigned());
        let loc = self.loc(span);
        let sym = match op {
            Add | WAdd => "+",
            Sub | WSub => "-",
            Mul | WMul => "*",
            Div => "/",
            Rem => "%",
            BitAnd => "&",
            BitOr => "|",
            BitXor => "^",
            _ => return err(span, "bad operator"),
        };
        Ok(match op {
            WAdd | WSub | WMul => format!("(({t})(({ut})({a}) {sym} ({ut})({b})))"),
            BitAnd | BitOr | BitXor => format!("(({t})(({a}) {sym} ({b})))"),
            Add | Sub | Mul if !self.opts.release => {
                let f = match op {
                    Add => "add",
                    Sub => "sub",
                    _ => "mul",
                };
                format!("({{ {t} _r; if (__builtin_{f}_overflow({a}, {b}, &_r)) volt_panic(\"integer overflow\", \"{loc}\"); _r; }})")
            }
            Div | Rem if !self.opts.release => {
                let min_check = if k.signed() {
                    format!(" if (_b == -1 && _a == ({t})(({ut})1 << {})) volt_panic(\"integer overflow\", \"{loc}\");", k.bits() - 1)
                } else {
                    String::new()
                };
                format!("({{ {t} _a = {a}, _b = {b}; if (_b == 0) volt_panic(\"division by zero\", \"{loc}\");{min_check} ({t})(_a {sym} _b); }})")
            }
            _ => format!("(({t})(({a}) {sym} ({b})))"),
        })
    }

    /// a << b, a >> b; debug builds trap when b is at least a's bit width
    pub(super) fn shift(&mut self, op: BinOp, a: Val, b: Val, span: Span) -> Res<Val> {
        let Some(k) = self.t.int_of(a.ty) else { return err(span, format!("can't shift a {}", self.ty_name(a.ty))) };
        let b = if b.lit.is_some() { self.coerce(b, int(IntTy::U32), span)? } else { b };
        if self.t.int_of(b.ty).is_none() {
            return err(span, "shift amount must be an integer");
        }
        let (t, ut) = (k.c(), k.c_unsigned());
        let sym = if op == BinOp::Shl { "<<" } else { ">>" };
        // shift the unsigned form left (C makes shifting negatives left undefined)
        let a_c = if op == BinOp::Shl { format!("({ut})({})", a.c) } else { a.c.clone() };
        let c = if self.opts.release {
            format!("(({t})(({a_c}) {sym} ({})))", b.c)
        } else {
            let loc = self.loc(span);
            format!(
                "({{ {t} _a = {}; uint64_t _s = (uint64_t)({}); if (_s >= {}) volt_panic(\"shift amount too large\", \"{loc}\"); ({t})({} {sym} _s); }})",
                a.c,
                b.c,
                k.bits(),
                if op == BinOp::Shl { format!("({ut})_a") } else { "_a".into() }
            )
        };
        let _ = a_c;
        Ok(Val::new(a.ty, c))
    }

    /// Comparisons: a pointer or optional against null, then numbers, pointers, bools, strs, errors and
    /// plain enums (only numbers and pointers are ordered).
    pub fn compare(&mut self, op: BinOp, a: Val, b: Val, span: Span) -> Res<Val> {
        use BinOp::*;
        let sym = match op {
            Eq => "==",
            Ne => "!=",
            Lt => "<",
            Gt => ">",
            Le => "<=",
            _ => ">=",
        };
        // optional or pointer vs null
        for (x, y) in [(&a, &b), (&b, &a)] {
            if y.ty == NULL && self.t.is_ptr(x.ty) {
                if !matches!(op, Eq | Ne) {
                    return err(span, "only == and != work with null");
                }
                return Ok(Val { pure: x.pure, ..Val::new(BOOL, format!("(({}) {sym} 0)", x.c)) });
            }
            if y.ty == NULL {
                if let Ty::Opt(inner) = self.t.get(x.ty).clone() {
                    if !matches!(op, Eq | Ne) {
                        return err(span, "only == and != work with null");
                    }
                    let is_null = if self.t.is_niche(inner) { format!("(({}) == 0)", x.c) } else { format!("(!({}).has)", x.c) };
                    let c = if op == Eq { is_null } else { format!("(!{is_null})") };
                    return Ok(Val { pure: x.pure, ..Val::new(BOOL, c) });
                }
            }
        }
        let (a, b) = self.unify(a, b, span)?;
        let mut pair = [a, b];
        let pre = self.seq(&mut pair);
        let [a, b] = pair;
        let ordered = matches!(op, Lt | Gt | Le | Ge);
        let c = match self.t.get(a.ty).clone() {
            Ty::Int(_) | Ty::Float(_) => format!("(({}) {sym} ({}))", a.c, b.c),
            Ty::Bool | Ty::Ref(_) | Ty::VoidPtr | Ty::FnPtr(..) if !ordered => format!("(({}) {sym} ({}))", a.c, b.c),
            Ty::Ptr(_) => format!("(({}) {sym} ({}))", a.c, b.c),
            Ty::Opt(inner) if !ordered && self.t.is_niche(inner) => format!("(({}) {sym} ({}))", a.c, b.c),
            Ty::Str if !ordered => format!("({}volt_str_eq({}, {}))", if op == Ne { "!" } else { "" }, a.c, b.c),
            Ty::AnyErr if !ordered => format!("(({}) {sym} ({}))", a.c, b.c),
            Ty::Enum(e) if !ordered && !self.enums[e as usize].has_payload => format!("(({}) {sym} ({}))", a.c, b.c),
            _ => return err(span, format!("can't compare {} with {sym}", self.ty_name(a.ty))),
        };
        Ok(Val { pure: a.pure && b.pure, ..Val::new(BOOL, Self::wrap_pre(&pre, c)) })
    }

    /// `l = r` and the compound forms (`l += r`...). A plain `=` goes through store (the value moves
    /// in, the old one is deleted); a compound one evaluates the target once.
    pub(super) fn assign(&mut self, op: Option<BinOp>, le: &Expr, re: &Expr, span: Span) -> Res<Val> {
        if let ExprKind::Path(p) = &le.kind {
            if p.is_single() && self.const_local(&p.segs[0].name).is_some() {
                return self.ct_assign(op, &p.segs[0].name, re, span);
            }
        }
        let l = self.expr(le, None)?;
        if !l.lv {
            return err(le.span, "can't assign to this; it's a temporary value");
        }
        if !l.mutable {
            if l.rop {
                return err(le.span, "can't assign through this; it reaches a val (or a parameter without var)");
            }
            return err(le.span, "can't assign to this; it's immutable (val, or a parameter without var)");
        }
        self.note_write(&l);
        self.note_mut(&l);
        let Some(op) = op else {
            // a narrowed optional takes either its payload type or the full optional back; a
            // narrowed pointer is always stored whole (its checked read would trap on a null one)
            if let Some(loc @ Local { orig: Some(_), .. }) = Self::place_key(le).and_then(|k| self.lookup_local(&k)) {
                let (oc, oty) = loc.orig.clone().unwrap();
                let r = self.expr(re, Some(l.ty))?;
                if !self.coercible(&r, l.ty) || self.narrow_recheck(&loc) {
                    let whole = Val { lv: true, mutable: l.mutable, ..Val::pure(oty, oc) };
                    return self.store(whole, r, re.span);
                }
                return self.store(l, r, re.span);
            }
            // `x = f(move x)` may move x even inside a loop: it gets a new value right away
            let target = l.owner.as_ref().and_then(|n| self.lookup_local(n)).map(|x| x.c);
            let saved = std::mem::replace(&mut self.cx.reassigning, target);
            // a local, or a field of one: nothing in the value can move its address (a longer chain
            // may read through a reference field the value's calls reassign)
            let fixed = l.pure
                && Self::place_key(le).is_some_and(|k| {
                    let mut parts = k.split('.');
                    let root = parts.next().unwrap();
                    parts.count() <= 1 && (root == "this" || self.lookup_local(root).is_some())
                });
            let r = self.expr(re, Some(l.ty)).and_then(|r| {
                // C leaves the order of `l = r` open; Volt evaluates r first
                if fixed || (r.pure && (l.pure || r.lit.is_some())) || self.needs_drop(l.ty)? {
                    return self.store(l, r, re.span);
                }
                let r = self.take_into(r, l.ty, re.span)?;
                Ok(Val::stmt(format!("({{ {} _v = {}; {} = _v; }})", self.cty(l.ty), r.c, l.c)))
            });
            self.cx.reassigning = saved;
            return r;
        };
        let r = self.expr(re, Some(l.ty))?;
        let lty = l.ty;
        let cty = self.cty(lty);
        // evaluate the target once
        let (pre, target) = if l.pure { (String::new(), l.c.clone()) } else { (format!("{cty}* _p = &({}); ", l.c), "(*_p)".to_string()) };
        let cur = Val { c: target.clone(), ..l.clone() };
        let v = if let Ty::Ptr(_) = self.t.get(lty) {
            // p += n, p -= n, p++, p--
            let r = if r.lit.is_some() { self.coerce(r, int(IntTy::Isize), re.span)? } else { r };
            if !matches!(op, BinOp::Add | BinOp::Sub) || self.t.int_of(r.ty).is_none() {
                return err(span, "pointers only move by an integer: p += n, p -= n, p++, p--");
            }
            Val::new(lty, format!("(({target}) {} ({}))", if op == BinOp::Add { "+" } else { "-" }, r.c))
        } else if matches!(op, BinOp::Shl | BinOp::Shr) {
            self.shift(op, cur, r, span)?
        } else {
            let r = self.coerce(r, lty, re.span)?;
            let c = match self.t.get(lty).clone() {
                Ty::Int(k) => self.int_arith(op, k, &target, &r.c, span)?,
                Ty::Float(_) if matches!(op, BinOp::Add | BinOp::Sub | BinOp::Mul | BinOp::Div) => {
                    let s = match op {
                        BinOp::Add => "+",
                        BinOp::Sub => "-",
                        BinOp::Mul => "*",
                        _ => "/",
                    };
                    format!("(({target}) {s} ({}))", r.c)
                }
                _ => return err(span, format!("can't use {}= on {}", op.text(), self.ty_name(lty))),
            };
            Val::new(lty, c)
        };
        let code = format!("{target} = {}", v.c);
        Ok(Val::stmt(if pre.is_empty() { code } else { format!("({{ {pre}{code}; }})") }))
    }

    /// `place = value`: the value moves in; an old value that owns something is deleted first
    pub(super) fn store(&mut self, l: Val, r: Val, span: Span) -> Res<Val> {
        let r = self.take_into(r, l.ty, span)?;
        if !self.needs_drop(l.ty)? {
            return Ok(Val::stmt(format!("{} = {}", l.c, r.c)));
        }
        let tc = self.cty(l.ty);
        let d = self.drop_fn(l.ty)?;
        if let Some(name) = &l.owner {
            let local = self.lookup_local(name).unwrap();
            let flag = local.flag.clone().unwrap();
            self.cx.moved.remove(&local.c);
            return Ok(Val::stmt(format!("({{ {tc} _n = {}; if ({flag}) {d}(&{}); {} = _n; {flag} = true; }})", r.c, l.c, l.c)));
        }
        Ok(Val::stmt(format!("({{ {tc} _n = {}; {tc}* _p = &({}); {d}(_p); *_p = _n; }})", r.c, l.c)))
    }

    /// `x as T`: lossless numeric conversions, int to float, bool or a plain enum to int, and the
    /// implicit conversions; anything that could lose data needs @cast
    pub(super) fn cast(&mut self, x: &Expr, to: TyId, span: Span) -> Res<Val> {
        let v = self.expr(x, Some(to))?;
        if v.ty == to {
            return Ok(v);
        }
        if v.lit.is_some() && self.coercible(&v, to) {
            return self.coerce(v, to, span);
        }
        let ok = match (self.t.get(v.ty), self.t.get(to)) {
            (Ty::Int(a), Ty::Int(b)) => a.widens_to(*b),
            (Ty::Int(_), Ty::Float(_)) | (Ty::Bool, Ty::Int(_)) => true,
            (Ty::Enum(e), Ty::Int(_)) => !self.enums[*e as usize].has_payload,
            (Ty::Float(a), Ty::Float(b)) => a <= b,
            _ => self.coercible(&v, to),
        };
        if !ok {
            return err(span, format!("can't convert {} to {} with 'as' (it could lose data; @cast<T>(x) converts unchecked)", self.ty_name(v.ty), self.ty_name(to)));
        }
        if self.t.int_of(to).is_some() || self.t.is_float(to) {
            let c = self.cty(to);
            return Ok(Val { pure: v.pure, ..Val::new(to, format!("(({c})({}))", v.c)) });
        }
        self.coerce(v, to, span)
    }

}
