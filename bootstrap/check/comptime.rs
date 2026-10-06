// Compile-time evaluation: a small tree-walking interpreter over the AST. Values carry their
// type (ints with VOID as "untyped literal"), so results can become C constants afterwards.
use super::*;

/// a compile-time value. Int and Float carry their type (VOID while an untyped literal); Opt carries the
/// optional type (T?, not T)
#[derive(Clone, Debug, PartialEq)]
pub enum CVal {
    Void,
    Null,
    Bool(bool),
    Int(i128, TyId), // VOID = an untyped literal
    Float(f64, TyId),
    Str(Vec<u8>),
    Type(TyId),
    Tuple(Vec<CVal>),
    Array(Vec<CVal>, TyId),                   // element type
    Struct(TyId, Vec<(String, CVal)>),        // TyId VOID = a comptime-only record (typeinfo)
    Variant(TyId, String, Option<Box<CVal>>), // enum value (TyId VOID for typeinfo kinds)
    Opt(TyId, Option<Box<CVal>>),
}

/// a return, break or continue on its way out to the call or loop that handles it
pub enum Flow {
    Ret(CVal),
    Brk(Option<String>, Option<CVal>),
    Cont(Option<String>),
}

/// why evaluation stopped early: an error, or control flow (Flow)
pub enum Ctl {
    Err(Diag),
    Flow(Flow),
}

impl From<Diag> for Ctl {
    fn from(d: Diag) -> Ctl {
        Ctl::Err(d)
    }
}

type CRes<T> = Result<T, Ctl>;

/// the most elements a { x; n } or {} makes at compile time (each is a value in memory)
const CT_ARRAY_MAX: u64 = 1 << 20;

fn cerr<T>(span: Span, msg: impl Into<String>) -> CRes<T> {
    Err(Ctl::Err(Diag::new(span, msg)))
}

/// one interpreted call: its scopes of name -> (value, mutable), and the env its names resolve in
pub struct CtFrame {
    pub scopes: Vec<HashMap<String, (CVal, bool)>>,
    pub env: Rc<Env>,
}

/// limits that turn an endless loop or recursion into an error
const MAX_STEPS: u64 = 20_000_000;
const MAX_DEPTH: usize = 256;

impl Checker {
    // ---------- entry points ----------

    /// Evaluate at compile time in the current checker context.
    pub fn ct_eval(&mut self, e: &Expr, want: Option<TyId>) -> Res<CVal> {
        let env = self.cx.env.clone();
        self.ct_eval_in(env, e, want)
    }

    /// Evaluate with names resolved in env, in a fresh frame; control flow can't leave it.
    pub fn ct_eval_in(&mut self, env: Rc<Env>, e: &Expr, want: Option<TyId>) -> Res<CVal> {
        self.ct.push(CtFrame { scopes: vec![HashMap::new()], env });
        let r = self.ct_expr(e, want);
        self.ct.pop();
        match r {
            Ok(v) => Ok(v),
            Err(Ctl::Err(d)) => Err(d),
            Err(Ctl::Flow(_)) => err(e.span, "return/break/continue can't leave a compile-time expression"),
        }
    }

    /// is this expression only meaningful at compile time (so it gets evaluated, not emitted)?
    pub fn is_ct_expr(&self, e: &Expr) -> bool {
        match &e.kind {
            ExprKind::Quote(_) => true,
            ExprKind::Builtin(n, _, _) => matches!(n.as_str(), "typeinfo" | "typeof" | "compile_error" | "cfg" | "attaches" | "has_method" | "has_field"),
            ExprKind::Call(c, _) => match &c.kind {
                ExprKind::Path(p) => {
                    let found = if p.segs.len() == 1 { self.lookup(self.cx.env.ns, &p.segs[0].name) } else { self.lookup_path_ns(self.cx.env.ns, p) };
                    let local = p.is_single() && self.lookup_local(&p.segs[0].name).is_some();
                    !local
                        && matches!(found, Some(Found::Decls(ds)) if !ds.is_empty() && ds.iter().all(|d| matches!(&self.decls[*d].item.kind, ItemKind::Fn(f) if f.is_comptime)))
                }
                _ => false,
            },
            ExprKind::Field(b, _, None) | ExprKind::Index(b, _) => self.is_ct_expr(b),
            ExprKind::Path(p) if p.is_single() => self.const_local(&p.segs[0].name).is_some(),
            _ => false,
        }
    }

    /// a comptime local visible from the running function
    pub fn const_local(&self, name: &str) -> Option<CVal> {
        for s in self.cx.scopes.iter().rev() {
            if s.vars.contains_key(name) {
                return None; // a runtime local shadows it
            }
            if let Some((v, _)) = s.consts.get(name) {
                return Some(v.clone());
            }
            if s.barrier {
                break;
            }
        }
        None
    }

    /// assigns a comptime var of the running fn (a comptime val can't change)
    fn set_const_local(&mut self, name: &str, v: CVal, span: Span) -> Res<()> {
        for s in self.cx.scopes.iter_mut().rev() {
            if let Some((slot, mutable)) = s.consts.get_mut(name) {
                if !*mutable {
                    return err(span, format!("'{name}' is a comptime val; it can't change"));
                }
                *slot = v;
                return Ok(());
            }
        }
        err(span, format!("no comptime variable '{name}'"))
    }

    /// comptime var/val inside a runtime function
    pub fn ct_let(&mut self, l: &Let) -> Res<()> {
        let PatKind::Bind(name) = &l.pat.kind else { return err(l.pat.span, "comptime variables take a single name") };
        let env = self.cx.env.clone();
        let ty = match &l.ty {
            Some(t) => Some(self.resolve_type(t, &env)?),
            None => None,
        };
        let v = match &l.init {
            Some(e) => {
                let v = self.ct_eval(e, ty)?;
                match ty {
                    Some(t) => self.ct_coerce_res(v, t, e.span)?,
                    None => v,
                }
            }
            None => CVal::Void,
        };
        self.cx.scopes.last_mut().unwrap().consts.insert(name.clone(), (v, l.mutable));
        Ok(())
    }

    /// `x = v` / `x += v` where x is a comptime local
    pub fn ct_assign(&mut self, op: Option<BinOp>, name: &str, rhs: &Expr, span: Span) -> Res<Val> {
        let cur = self.const_local(name).unwrap();
        let r = self.ct_eval(rhs, None)?;
        let v = match op {
            None => r,
            Some(op) => match self.ct_binop(op, cur, r, span) {
                Ok(v) => v,
                Err(Ctl::Err(d)) => return Err(d),
                Err(Ctl::Flow(_)) => unreachable!(),
            },
        };
        self.set_const_local(name, v, span)?;
        Ok(Val::stmt("((void)0)"))
    }

    // ---------- materializing ----------

    /// a compile-time value as C for the runtime code; types and typeinfo records can't cross over
    pub fn ct_to_val(&mut self, v: CVal, want: Option<TyId>, span: Span) -> Res<Val> {
        Ok(match v {
            CVal::Void => Val::stmt("((void)0)"),
            CVal::Null => match want {
                Some(w) if matches!(self.t.get(w), Ty::Opt(_)) => self.none(w),
                _ => Val::pure(NULL, "NULL"),
            },
            CVal::Bool(b) => Val::pure(BOOL, if b { "true" } else { "false" }),
            CVal::Int(x, VOID) => self.int_lit(x, want),
            CVal::Int(x, t) => self.int_lit(x, Some(t)),
            CVal::Float(x, t) => {
                let t = if t == VOID { want.filter(|w| self.t.is_float(*w)).unwrap_or(F64) } else { t };
                let lit = Expr { kind: ExprKind::Float(x), span };
                self.expr(&lit, Some(t))?
            }
            CVal::Str(s) => {
                let v = self.str_val(&s);
                if want == Some(CSTR) { self.coerce(v, CSTR, span)? } else { v }
            }
            CVal::Type(t) => return err(span, format!("the type {} is only a value at compile time", self.ty_name(t))),
            CVal::Tuple(elems) => {
                let mut vals = Vec::new();
                for e in elems {
                    vals.push(self.ct_to_val(e, None, span)?);
                }
                let ty = self.t.intern(Ty::Tuple(vals.iter().map(|v| v.ty).collect(), vec![None; vals.len()]));
                let c = self.cty(ty);
                let inits: Vec<String> = vals.iter().enumerate().map(|(i, v)| format!(".f{i} = {}", v.c)).collect();
                Val::pure(ty, format!("(({c}){{ {} }})", inits.join(", ")))
            }
            CVal::Array(elems, et) => {
                // an untyped list: its first element's type when that has one (an untyped literal's doesn't), else i32
                let et = if et == VOID { elems.first().map(|e| self.ct_type_of(e)).filter(|t| *t != VOID).unwrap_or(I32) } else { et };
                let ty = self.t.intern(Ty::Array(et, elems.len() as u64));
                let mut cs = Vec::new();
                for e in elems {
                    let v = self.ct_to_val(e, Some(et), span)?;
                    cs.push(self.coerce(v, et, span)?.c);
                }
                let c = self.cty(ty);
                Val::pure(ty, format!("(({c}){{ {{ {} }} }})", cs.join(", ")))
            }
            CVal::Struct(VOID, _) => return err(span, "this compile-time record (like typeinfo) can't exist at runtime; read one of its fields"),
            CVal::Struct(t, fields) => {
                let mut inits = Vec::new();
                let infos = match self.t.get(t).clone() {
                    Ty::Struct(sid) => self.struct_fields(sid, span)?,
                    _ => return err(span, "bad struct value"),
                };
                for (n, fv) in fields {
                    let fty = infos.iter().find(|f| f.name == n).map(|f| f.ty);
                    let v = self.ct_to_val(fv, fty, span)?;
                    let v = match fty {
                        Some(ft) => self.coerce(v, ft, span)?,
                        None => v,
                    };
                    inits.push(format!(".{} = {}", c_field(&n), v.c));
                }
                let c = self.cty(t);
                Val::pure(t, format!("(({c}){{ {} }})", inits.join(", ")))
            }
            CVal::Variant(VOID, n, _) => return err(span, format!("{n} is a compile-time-only value")),
            CVal::Variant(t, n, payload) => {
                let eid = self.enum_of(t).unwrap();
                let idx = self.variant_index(eid, &n).unwrap();
                match payload {
                    None => self.make_variant(t, idx, None, span)?,
                    Some(p) => {
                        let pv = self.ct_to_val(*p, None, span)?;
                        let tmp = self.tmp("cv");
                        let tc = self.cty(pv.ty);
                        self.cx.scopes.last_mut().unwrap().vars.insert(tmp.clone(), Local { c: tmp.clone(), ty: pv.ty, mutable: false, orig: None, flag: None, loops: 0, ro: 0, via: None, root: None, param: false, own: None });
                        let arg = Expr { kind: ExprKind::Path(Path::single(&tmp, span)), span };
                        let v = self.make_variant(t, idx, Some(std::slice::from_ref(&arg)), span)?;
                        Val::new(t, format!("({{ {tc} {tmp} = {}; {}; }})", pv.c, v.c))
                    }
                }
            }
            CVal::Opt(t, None) => self.none(t),
            CVal::Opt(t, Some(v)) => {
                let Ty::Opt(inner) = self.t.get(t).clone() else { unreachable!() };
                let iv = self.ct_to_val(*v, Some(inner), span)?;
                let iv = self.coerce(iv, inner, span)?;
                self.some(iv, t)
            }
        })
    }

    /// the type of a compile-time value; an untyped int is i32 and an untyped float f64
    pub fn ct_type_of(&mut self, v: &CVal) -> TyId {
        match v {
            CVal::Void => VOID,
            CVal::Null => NULL,
            CVal::Bool(_) => BOOL,
            CVal::Int(_, VOID) => I32,
            CVal::Int(_, t) => *t,
            CVal::Float(_, VOID) => F64,
            CVal::Float(_, t) => *t,
            CVal::Str(_) => STR,
            CVal::Type(_) => TYPE,
            CVal::Tuple(es) => {
                let ts: Vec<TyId> = es.iter().map(|e| self.ct_type_of(e)).collect();
                let n = ts.len();
                self.t.intern(Ty::Tuple(ts, vec![None; n]))
            }
            CVal::Array(es, et) => {
                let et = if *et == VOID { es.first().map(|e| self.ct_type_of(e)).unwrap_or(I32) } else { *et };
                self.t.intern(Ty::Array(et, es.len() as u64))
            }
            CVal::Struct(t, _) | CVal::Variant(t, _, _) | CVal::Opt(t, _) => *t,
        }
    }

    fn ct_coerce_res(&mut self, v: CVal, ty: TyId, span: Span) -> Res<CVal> {
        match self.ct_coerce(v, ty, span) {
            Ok(v) => Ok(v),
            Err(Ctl::Err(d)) => Err(d),
            Err(Ctl::Flow(_)) => unreachable!(),
        }
    }

    /// converts v to ty by the implicit rules: ints must fit, a value wraps into an optional, arrays and
    /// tuples convert element by element
    fn ct_coerce(&mut self, v: CVal, ty: TyId, span: Span) -> CRes<CVal> {
        let have = self.ct_type_of(&v);
        if have == ty || ty == TYPE && matches!(v, CVal::Type(_)) {
            return Ok(v);
        }
        Ok(match (v, self.t.get(ty).clone()) {
            (CVal::Int(x, from), Ty::Int(k)) => {
                if from != VOID && !self.t.int_of(from).is_some_and(|f| f.widens_to(k)) && !k.fits(x) {
                    return cerr(span, format!("{x} doesn't fit in {}", k.name()));
                }
                if !k.fits(x) {
                    return cerr(span, format!("{x} doesn't fit in {}", k.name()));
                }
                CVal::Int(x, ty)
            }
            (CVal::Int(x, _), Ty::Float(_)) => CVal::Float(x as f64, ty),
            (CVal::Float(x, _), Ty::Float(_)) => CVal::Float(x, ty),
            (CVal::Str(s), Ty::CStr) => CVal::Str(s),
            (CVal::Null, Ty::Opt(_)) => CVal::Opt(ty, None),
            (CVal::Opt(_, inner), Ty::Opt(_)) => CVal::Opt(ty, inner),
            (v, Ty::Opt(inner)) => {
                let v = self.ct_coerce(v, inner, span)?;
                CVal::Opt(ty, Some(Box::new(v)))
            }
            (CVal::Array(es, _), Ty::Array(et, n)) if es.len() as u64 == n => {
                let mut out = Vec::new();
                for e in es {
                    out.push(self.ct_coerce(e, et, span)?);
                }
                CVal::Array(out, et)
            }
            (CVal::Tuple(es), Ty::Tuple(ts, _)) if es.len() == ts.len() => {
                let mut out = Vec::new();
                for (e, t) in es.into_iter().zip(ts) {
                    out.push(self.ct_coerce(e, t, span)?);
                }
                CVal::Tuple(out)
            }
            (v, _) => {
                let have = self.ct_type_of(&v);
                return Err(Diag::new(span, format!("expected {}, found {}", self.ty_name(ty), self.ty_name(have))).type_diff().into());
            }
        })
    }

    // ---------- the interpreter ----------

    fn frame(&mut self) -> &mut CtFrame {
        self.ct.last_mut().unwrap()
    }

    /// a variable of the running interpreted call; the outermost frame also sees the fn's comptime locals
    fn ct_lookup(&mut self, name: &str) -> Option<CVal> {
        let f = self.ct.last().unwrap();
        for s in f.scopes.iter().rev() {
            if let Some((v, _)) = s.get(name) {
                return Some(v.clone());
            }
        }
        if self.ct.len() == 1 {
            if let Some(v) = self.const_local(name) {
                return Some(v);
            }
        }
        None
    }

    /// assigns an existing variable; a val can't change
    fn ct_set(&mut self, name: &str, v: CVal, span: Span) -> CRes<()> {
        let f = self.ct.last_mut().unwrap();
        for s in f.scopes.iter_mut().rev() {
            if let Some((slot, mutable)) = s.get_mut(name) {
                if !*mutable {
                    return cerr(span, format!("'{name}' is a val; it can't change"));
                }
                *slot = v;
                return Ok(());
            }
        }
        if self.ct.len() == 1 && self.const_local(name).is_some() {
            self.set_const_local(name, v, span)?;
            return Ok(());
        }
        cerr(span, format!("'{name}' isn't a compile-time variable"))
    }

    /// counts one evaluation step; past MAX_STEPS it's an error
    fn step(&mut self, span: Span) -> CRes<()> {
        self.ct_steps += 1;
        if self.ct_steps > MAX_STEPS {
            return cerr(span, "compile-time evaluation took too long (over 20M steps); is there an endless loop?");
        }
        Ok(())
    }

    /// a name at compile time: an interpreted variable, a generic param, a primitive type, a global val's
    /// value (its initializer, evaluated again on each use), a type, or Enum::VARIANT
    fn ct_path(&mut self, p: &Path, want: Option<TyId>, span: Span) -> CRes<CVal> {
        if p.is_single() {
            let name = &p.segs[0].name;
            if let Some(v) = self.ct_lookup(name) {
                if v == CVal::Void {
                    return cerr(span, format!("'{name}' has no value yet"));
                }
                return Ok(v);
            }
            let env = self.frame().env.clone();
            if let Some((_, g)) = env.generics.iter().rev().find(|(n, _)| n == name) {
                return Ok(match g {
                    GVal::Ty(t) => CVal::Type(*t),
                    GVal::Int(v) => CVal::Int(*v, VOID),
                    GVal::Str(s) => CVal::Str(s.clone()),
                    GVal::Pack(ts) => CVal::Tuple(ts.iter().map(|t| CVal::Type(*t)).collect()),
                });
            }
            if self.ct.len() == 1 && self.lookup_local(name).is_some() {
                return cerr(span, format!("'{name}' is a runtime variable, so its value isn't known at compile time"));
            }
            if let Some(t) = Types::primitive(name) {
                return Ok(CVal::Type(t));
            }
        }
        let env = self.frame().env.clone();
        let found = if p.segs.len() == 1 { self.lookup(env.ns, &p.segs[0].name) } else { self.lookup_path_ns(env.ns, p) };
        match found {
            Some(Found::Decls(ds)) => {
                let d = ds[0];
                self.visible(d, span)?;
                match &self.decls[d].item.clone().kind {
                    ItemKind::Global(l) => {
                        if l.mutable && !l.comptime {
                            return cerr(span, format!("'{}' is a runtime var; its value isn't known at compile time", p.last()));
                        }
                        let Some(init) = &l.init else { return cerr(span, "this global has no value") };
                        let genv = Rc::new(Env { ns: self.decls[d].ns, generics: Vec::new() });
                        // the declared type guides the value (a struct literal is that struct)
                        match &l.ty {
                            Some(t) => {
                                let t = self.resolve_type(t, &genv)?;
                                let v = self.ct_eval_in(genv.clone(), init, Some(t))?;
                                self.ct_coerce(v, t, span)
                            }
                            None => Ok(self.ct_eval_in(genv.clone(), init, None)?),
                        }
                    }
                    ItemKind::Struct(_) | ItemKind::Enum(_) | ItemKind::Trait { .. } => {
                        let ty = self.resolve_type_path(p, &env)?;
                        Ok(CVal::Type(ty))
                    }
                    _ => cerr(span, format!("'{}' isn't a compile-time value", p.last())),
                }
            }
            _ => {
                // Enum::VARIANT or a type path
                if let Some(generics::Member::Of(ty, member)) = self.member_path(p)? {
                    if let Some(eid) = self.enum_of(ty) {
                        if self.variant_index(eid, &member).is_some() {
                            return Ok(CVal::Variant(ty, member, None));
                        }
                    }
                }
                if let Ok(ty) = self.resolve_type_path(p, &env) {
                    return Ok(CVal::Type(ty));
                }
                let _ = want;
                cerr(span, format!("unknown name '{}'", p.last()))
            }
        }
    }

    /// evaluates e; want types untyped literals and resolves `.VARIANT`. Blocks and ifs give no value
    /// (only a break out of a labeled block or a `loop` carries one)
    pub fn ct_expr(&mut self, e: &Expr, want: Option<TyId>) -> CRes<CVal> {
        self.step(e.span)?;
        let span = e.span;
        match &e.kind {
            ExprKind::Int(v) => Ok(CVal::Int(*v as i128, want.filter(|w| self.t.int_of(*w).is_some()).unwrap_or(VOID))),
            ExprKind::Char(v) => Ok(CVal::Int(*v as i128, VOID)),
            ExprKind::Float(v) => Ok(CVal::Float(*v, want.filter(|w| self.t.is_float(*w)).unwrap_or(VOID))),
            ExprKind::Str(s) => Ok(CVal::Str(s.clone())),
            ExprKind::TypeBody(b) => self.ct_type_body(b, span),
            ExprKind::Quote(parts) => {
                let mut out = String::new();
                for p in parts {
                    match p {
                        QuotePart::Text(t) => out.push_str(t),
                        QuotePart::Splice(x) => {
                            let v = self.ct_expr(x, None)?;
                            out.push_str(&self.splice_text(v, x.span)?);
                        }
                    }
                }
                Ok(CVal::Str(out.into_bytes()))
            }
            ExprKind::Bool(b) => Ok(CVal::Bool(*b)),
            ExprKind::Null => Ok(CVal::Null),
            ExprKind::Path(p) => self.ct_path(p, want, span),
            ExprKind::DotVariant(n) => match self.dot_target(want) {
                Some(t) => Ok(CVal::Variant(t, n.clone(), None)),
                None => cerr(span, format!("can't tell which enum .{n} belongs to")),
            },
            ExprKind::Unary(op, x) => {
                let v = self.ct_expr(x, want)?;
                match (op, v) {
                    (UnOp::Neg, CVal::Int(n, t)) => Ok(CVal::Int(-n, t)),
                    (UnOp::Neg, CVal::Float(f, t)) => Ok(CVal::Float(-f, t)),
                    (UnOp::Not, CVal::Bool(b)) => Ok(CVal::Bool(!b)),
                    (UnOp::BitNot, CVal::Int(n, t)) => Ok(CVal::Int(!n, t)),
                    _ => cerr(span, "this operator doesn't work on that value at compile time"),
                }
            }
            ExprKind::Binary(op, a, b) => {
                if matches!(op, BinOp::And | BinOp::Or) {
                    let av = self.ct_bool(a)?;
                    if (*op == BinOp::And) != av {
                        return Ok(CVal::Bool(av));
                    }
                    return Ok(CVal::Bool(self.ct_bool(b)?));
                }
                let av = self.ct_expr(a, None)?;
                let at = if matches!(av, CVal::Int(_, VOID)) { None } else { Some(self.ct_type_of(&av)) };
                let bv = self.ct_expr(b, at)?;
                self.ct_binop(*op, av, bv, span)
            }
            ExprKind::Assign(op, l, r) => {
                let rv = self.ct_expr(r, None)?;
                self.ct_store(l, *op, rv, span)?;
                Ok(CVal::Void)
            }
            ExprKind::IncDec(x, inc) => {
                let one = CVal::Int(1, VOID);
                self.ct_store(x, Some(if *inc { BinOp::Add } else { BinOp::Sub }), one, span)?;
                Ok(CVal::Void)
            }
            ExprKind::Cast(x, t) => {
                let env = self.frame().env.clone();
                let to = self.resolve_type(t, &env)?;
                let v = self.ct_expr(x, Some(to))?;
                self.ct_convert(v, to, false, span)
            }
            ExprKind::Tuple(es) => {
                let mut out = Vec::new();
                for x in es {
                    out.push(self.ct_expr(x, None)?);
                }
                Ok(CVal::Tuple(out))
            }
            ExprKind::Literal(entries) => self.ct_literal(entries, want, span),
            ExprKind::Repeat(x, n) => {
                // inside an optional: the array, present
                if let Some(w) = want {
                    if let Ty::Opt(inner) = self.t.get(w).clone() {
                        let v = self.ct_expr(e, Some(inner))?;
                        return Ok(CVal::Opt(w, Some(Box::new(v))));
                    }
                }
                let count = match self.ct_expr(n, None)? {
                    CVal::Int(c, _) if c >= 0 => c,
                    _ => return cerr(n.span, "a repeat count is an integer, 0 or more"),
                };
                if count > CT_ARRAY_MAX as i128 {
                    return cerr(span, format!("a repeat at compile time makes at most {CT_ARRAY_MAX} elements"));
                }
                let (et, v) = match want.map(|w| self.t.get(w).clone()) {
                    Some(Ty::Array(et, len)) => {
                        if count != len as i128 {
                            return cerr(span, format!("this repeats {count} times but the array holds {len}"));
                        }
                        let v = self.ct_expr(x, Some(et))?;
                        (et, self.ct_coerce(v, et, span)?)
                    }
                    None => (VOID, self.ct_expr(x, None)?), // untyped, as a { a, b } list is
                    Some(_) => return cerr(span, "a { x; n } literal makes an array"),
                };
                Ok(CVal::Array(vec![v; count as usize], et))
            }
            ExprKind::Field(b, name, _) => {
                let bv = self.ct_expr(b, None)?;
                self.ct_field(bv, name, span)
            }
            ExprKind::Index(b, i) => {
                let bv = self.ct_expr(b, None)?;
                let iv = self.ct_expr(i, Some(USIZE))?;
                let CVal::Int(i, _) = iv else { return cerr(span, "index must be an integer") };
                match bv {
                    CVal::Array(es, _) | CVal::Tuple(es) => match es.get(i as usize) {
                        Some(v) if i >= 0 => Ok(v.clone()),
                        _ => cerr(span, format!("index {i} out of bounds (len {})", es.len())),
                    },
                    CVal::Str(s) => match s.get(i as usize) {
                        Some(c) if i >= 0 => Ok(CVal::Int(*c as i128, U8)),
                        _ => cerr(span, format!("index {i} out of bounds (len {})", s.len())),
                    },
                    _ => cerr(span, "can't index this at compile time"),
                }
            }
            ExprKind::Call(callee, args) => self.ct_call_expr(callee, args, want, span),
            ExprKind::Builtin(name, gargs, args) => self.ct_builtin(name, gargs, args.as_deref().unwrap_or(&[]), want, span),
            ExprKind::Return(v) => {
                let v = match v {
                    Some(x) => self.ct_expr(x, None)?,
                    None => CVal::Void,
                };
                Err(Ctl::Flow(Flow::Ret(v)))
            }
            ExprKind::Break(l, v) => {
                let v = match v {
                    Some(x) => Some(self.ct_expr(x, None)?),
                    None => None,
                };
                Err(Ctl::Flow(Flow::Brk(l.clone(), v)))
            }
            ExprKind::Continue(l) => Err(Ctl::Flow(Flow::Cont(l.clone()))),
            ExprKind::Block(label, b) => match self.ct_block(b) {
                Err(Ctl::Flow(Flow::Brk(Some(l), v))) if label.as_deref() == Some(l.as_str()) => Ok(v.unwrap_or(CVal::Void)),
                r => r.map(|_| CVal::Void),
            },
            ExprKind::If { cond, then, els, .. } => {
                if self.ct_bool(cond)? {
                    self.ct_block(then)?;
                } else if let Some(e) = els {
                    self.ct_expr(e, None)?;
                }
                Ok(CVal::Void)
            }
            ExprKind::Loop(label, b) => loop {
                match self.ct_block(b) {
                    Ok(()) => {}
                    Err(Ctl::Flow(Flow::Brk(l, v))) if l.is_none() || l == *label => return Ok(v.unwrap_or(CVal::Void)),
                    Err(Ctl::Flow(Flow::Cont(l))) if l.is_none() || l == *label => {}
                    Err(e) => return Err(e),
                }
            },
            ExprKind::While(label, cond, b) => {
                while self.ct_bool(cond)? {
                    match self.ct_block(b) {
                        Ok(()) => {}
                        Err(Ctl::Flow(Flow::Brk(l, _))) if l.is_none() || l == *label => break,
                        Err(Ctl::Flow(Flow::Cont(l))) if l.is_none() || l == *label => {}
                        Err(e) => return Err(e),
                    }
                }
                Ok(CVal::Void)
            }
            ExprKind::For(f) => self.ct_for(f, span),
            ExprKind::Match { scrut, arms, .. } => {
                let v = self.ct_expr(scrut, None)?;
                for arm in arms {
                    self.frame().scopes.push(HashMap::new());
                    let r = (|| -> CRes<Option<CVal>> {
                        if !self.ct_pat(&arm.pat, &v)? {
                            return Ok(None);
                        }
                        if let Some(g) = &arm.guard {
                            if !self.ct_bool(g)? {
                                return Ok(None);
                            }
                        }
                        Ok(Some(self.ct_expr(&arm.body, want)?))
                    })();
                    self.frame().scopes.pop();
                    if let Some(out) = r? {
                        return Ok(out);
                    }
                }
                cerr(span, "no match arm matched at compile time")
            }
            ExprKind::OrElse(a, b) => match self.ct_expr(a, None)? {
                CVal::Opt(_, Some(v)) => Ok(*v),
                CVal::Opt(_, None) | CVal::Null => self.ct_expr(b, want),
                v => Ok(v),
            },
            ExprKind::Move(x) | ExprKind::Copy(x) => self.ct_expr(x, want),
            ExprKind::Range(..) => cerr(span, "ranges only work in for loops at compile time"),
            _ => cerr(span, "this isn't supported at compile time"),
        }
    }

    /// a condition: a bool, or an optional (present?)
    fn ct_bool(&mut self, e: &Expr) -> CRes<bool> {
        match self.ct_expr(e, Some(BOOL))? {
            CVal::Bool(b) => Ok(b),
            CVal::Opt(_, v) => Ok(v.is_some()),
            _ => cerr(e.span, "expected a bool"),
        }
    }

    /// a binary op on two values. Ints must share a type (an untyped literal takes the other's) and fit it;
    /// wrapping ops wrap to the type's width (32 bits when untyped). An int meeting a float becomes a float
    pub fn ct_binop(&mut self, op: BinOp, a: CVal, b: CVal, span: Span) -> CRes<CVal> {
        use BinOp::*;
        Ok(match (a, b) {
            (CVal::Int(x, ta), CVal::Int(y, tb)) => {
                let t = if ta == VOID { tb } else { ta };
                if ta != VOID && tb != VOID && ta != tb {
                    let (na, nb) = (self.ty_name(ta), self.ty_name(tb));
                    return Err(Diag::new(span, format!("mismatched types {na} and {nb}")).type_diff().into());
                }
                let k = self.t.int_of(t);
                let r = match op {
                    Add => x.checked_add(y),
                    Sub => x.checked_sub(y),
                    Mul => x.checked_mul(y),
                    Div => x.checked_div(y),
                    Rem => x.checked_rem(y),
                    WAdd | WSub | WMul => {
                        let r = match op {
                            WAdd => x.wrapping_add(y),
                            WSub => x.wrapping_sub(y),
                            _ => x.wrapping_mul(y),
                        };
                        let bits = k.map(|k| k.bits()).unwrap_or(32);
                        let signed = k.map(|k| k.signed()).unwrap_or(true);
                        let m = if bits >= 128 { r } else { r & ((1i128 << bits) - 1) };
                        Some(if signed && bits < 128 && m >= (1i128 << (bits - 1)) { m - (1i128 << bits) } else { m })
                    }
                    BitAnd => Some(x & y),
                    BitOr => Some(x | y),
                    BitXor => Some(x ^ y),
                    Shl => u32::try_from(y).ok().and_then(|y| x.checked_shl(y)),
                    Shr => u32::try_from(y).ok().and_then(|y| x.checked_shr(y)),
                    Eq => return Ok(CVal::Bool(x == y)),
                    Ne => return Ok(CVal::Bool(x != y)),
                    Lt => return Ok(CVal::Bool(x < y)),
                    Gt => return Ok(CVal::Bool(x > y)),
                    Le => return Ok(CVal::Bool(x <= y)),
                    Ge => return Ok(CVal::Bool(x >= y)),
                    And | Or => None,
                };
                let Some(r) = r else { return cerr(span, "integer overflow or division by zero at compile time") };
                if let Some(k) = k {
                    if !k.fits(r) {
                        return cerr(span, format!("integer overflow at compile time: {r} doesn't fit in {}", k.name()));
                    }
                }
                CVal::Int(r, t)
            }
            (CVal::Float(x, ta), CVal::Float(y, tb)) => {
                let t = if ta == VOID { tb } else { ta };
                match op {
                    Add => CVal::Float(x + y, t),
                    Sub => CVal::Float(x - y, t),
                    Mul => CVal::Float(x * y, t),
                    Div => CVal::Float(x / y, t),
                    Eq => CVal::Bool(x == y),
                    Ne => CVal::Bool(x != y),
                    Lt => CVal::Bool(x < y),
                    Gt => CVal::Bool(x > y),
                    Le => CVal::Bool(x <= y),
                    Ge => CVal::Bool(x >= y),
                    _ => return cerr(span, "this operator doesn't work on floats"),
                }
            }
            (CVal::Int(x, _), f @ CVal::Float(..)) => return self.ct_binop(op, CVal::Float(x as f64, VOID), f, span),
            (f @ CVal::Float(..), CVal::Int(y, _)) => return self.ct_binop(op, f, CVal::Float(y as f64, VOID), span),
            (CVal::Str(mut x), CVal::Str(y)) if op == Add => {
                x.extend(y);
                CVal::Str(x)
            }
            (a, b) if matches!(op, Eq | Ne) => {
                let same = match (&a, &b) {
                    (CVal::Null, CVal::Opt(_, v)) | (CVal::Opt(_, v), CVal::Null) => v.is_none(),
                    _ => a == b,
                };
                CVal::Bool(same == (op == Eq))
            }
            _ => return cerr(span, "can't use this operator on these values at compile time"),
        })
    }

    /// an explicit conversion (`as`); with unchecked (@cast) an int wraps to fit and a float truncates
    fn ct_convert(&mut self, v: CVal, to: TyId, unchecked: bool, span: Span) -> CRes<CVal> {
        Ok(match (v, self.t.get(to).clone()) {
            (CVal::Int(x, _), Ty::Int(k)) => {
                if !k.fits(x) {
                    if !unchecked {
                        return cerr(span, format!("{x} doesn't fit in {}", k.name()));
                    }
                    let bits = k.bits();
                    let m = if bits >= 128 { x } else { x & ((1i128 << bits) - 1) };
                    CVal::Int(if k.signed() && bits < 128 && m >= (1i128 << (bits - 1)) { m - (1i128 << bits) } else { m }, to)
                } else {
                    CVal::Int(x, to)
                }
            }
            (CVal::Int(x, _), Ty::Float(_)) => CVal::Float(x as f64, to),
            (CVal::Float(x, _), Ty::Float(_)) => CVal::Float(x, to),
            (CVal::Float(x, _), Ty::Int(_)) if unchecked => CVal::Int(x as i128, to),
            (CVal::Bool(b), Ty::Int(_)) => CVal::Int(b as i128, to),
            (CVal::Variant(t, n, None), Ty::Int(_)) => {
                // typeinfo kinds (BOOL, VOID, ...) are variants of no real enum
                let Some(eid) = self.enum_of(t) else { return cerr(span, format!("can't cast .{n} to an integer")) };
                let i = self.variant_index(eid, &n).unwrap();
                CVal::Int(self.enums[eid as usize].values[i], to)
            }
            (v, _) => self.ct_coerce(v, to, span)?,
        })
    }

    /// `place op= value` inside the interpreter
    fn ct_store(&mut self, place: &Expr, op: Option<BinOp>, v: CVal, span: Span) -> CRes<()> {
        // path of names/fields/indexes down to a variable
        fn root(e: &Expr) -> Option<&str> {
            match &e.kind {
                ExprKind::Path(p) if p.is_single() => Some(&p.segs[0].name),
                ExprKind::Field(b, _, _) | ExprKind::Index(b, _) => root(b),
                _ => None,
            }
        }
        let Some(name) = root(place) else { return cerr(span, "can't assign to this at compile time") };
        let name = name.to_string();
        let Some(mut whole) = self.ct_lookup(&name) else { return cerr(span, format!("'{name}' isn't a compile-time variable")) };
        let new = match op {
            None => v,
            Some(op) => {
                let cur = self.ct_expr(place, None)?;
                self.ct_binop(op, cur, v, span)?
            }
        };
        self.ct_write(&mut whole, place, new, span)?;
        self.ct_set(&name, whole, span)
    }

    /// stores v at place inside whole (the root variable's value), rebuilding each parent on the way up
    fn ct_write(&mut self, whole: &mut CVal, place: &Expr, v: CVal, span: Span) -> CRes<()> {
        match &place.kind {
            ExprKind::Path(_) => {
                let t = self.ct_type_of(whole);
                *whole = if matches!(whole, CVal::Void) || t == VOID { v } else { self.ct_coerce(v, t, span)? };
                Ok(())
            }
            ExprKind::Field(b, name, _) => {
                let mut parent = self.ct_expr(b, None)?;
                match &mut parent {
                    CVal::Struct(_, fields) => match fields.iter_mut().find(|(n, _)| n == name) {
                        Some((_, slot)) => *slot = v,
                        None => return cerr(span, format!("no field '{name}'")),
                    },
                    CVal::Tuple(es) => match name.parse::<usize>().ok().and_then(|i| es.get_mut(i)) {
                        Some(slot) => *slot = v,
                        None => return cerr(span, format!("no field '{name}'")),
                    },
                    _ => return cerr(span, "can't assign a field of this at compile time"),
                }
                self.ct_write(whole, b, parent, span)
            }
            ExprKind::Index(b, i) => {
                let mut parent = self.ct_expr(b, None)?;
                let CVal::Int(i, _) = self.ct_expr(i, Some(USIZE))? else { return cerr(span, "index must be an integer") };
                match &mut parent {
                    CVal::Array(es, _) => match es.get_mut(i as usize) {
                        Some(slot) if i >= 0 => *slot = v,
                        _ => return cerr(span, format!("index {i} out of bounds")),
                    },
                    _ => return cerr(span, "can't index this at compile time"),
                }
                self.ct_write(whole, b, parent, span)
            }
            _ => cerr(span, "can't assign to this at compile time"),
        }
    }

    /// the value a `var x: T;` starts with, at compile time (what `{}` makes for an array)
    fn ct_zero(&mut self, t: TyId, span: Span) -> CRes<CVal> {
        Ok(match self.t.get(t).clone() {
            Ty::Int(_) => CVal::Int(0, t),
            Ty::Float(_) => CVal::Float(0.0, t),
            Ty::Bool => CVal::Bool(false),
            Ty::Opt(_) => CVal::Opt(t, None),
            Ty::Array(_, n) if n > CT_ARRAY_MAX => return cerr(span, format!("an array at compile time holds at most {CT_ARRAY_MAX} elements")),
            Ty::Array(et, n) => CVal::Array(vec![self.ct_zero(et, span)?; n as usize], et),
            Ty::Tuple(ts, _) => CVal::Tuple(ts.into_iter().map(|x| self.ct_zero(x, span)).collect::<CRes<_>>()?),
            Ty::Struct(sid) if !self.header_struct(sid) => {
                let fields = self.struct_fields(sid, span)?;
                let mut out = Vec::new();
                for f in fields.iter() {
                    let v = match &f.default {
                        Some(d) => {
                            let env = self.structs[sid as usize].env.clone();
                            let v = self.ct_eval_in(env, d, Some(f.ty))?;
                            self.ct_coerce(v, f.ty, span)?
                        }
                        None => self.ct_zero(f.ty, span)?,
                    };
                    out.push((f.name.clone(), v));
                }
                CVal::Struct(t, out)
            }
            _ => return cerr(span, format!("a {} has no zero value at compile time", self.ty_name(t))),
        })
    }

    /// `{ ... }` at compile time: a struct or array of the wanted type, or an untyped list when none is
    /// wanted
    fn ct_literal(&mut self, entries: &[(Option<String>, Expr)], want: Option<TyId>, span: Span) -> CRes<CVal> {
        let Some(w) = want else {
            let mut es = Vec::new();
            for (_, e) in entries {
                es.push(self.ct_expr(e, None)?);
            }
            return Ok(CVal::Array(es, VOID));
        };
        match self.t.get(w).clone() {
            Ty::Struct(sid) => {
                let fields = self.struct_fields(sid, span)?;
                let mut out = Vec::new();
                for f in fields.iter() {
                    let given = entries.iter().find(|(n, e)| n.as_deref() == Some(&f.name) || (n.is_none() && matches!(&e.kind, ExprKind::Path(p) if p.is_single() && p.segs[0].name == f.name)));
                    let v = match (given, &f.default) {
                        (Some((_, e)), _) => self.ct_expr(e, Some(f.ty))?,
                        (None, Some(d)) => {
                            let env = self.structs[sid as usize].env.clone();
                            self.ct_eval_in(env, d, Some(f.ty))?
                        }
                        (None, None) if matches!(self.t.get(f.ty), Ty::Opt(_)) => CVal::Opt(f.ty, None),
                        (None, None) => return cerr(span, format!("missing field '{}'", f.name)),
                    };
                    out.push((f.name.clone(), self.ct_coerce(v, f.ty, span)?));
                }
                Ok(CVal::Struct(w, out))
            }
            Ty::Array(et, n) => {
                if entries.is_empty() {
                    return self.ct_zero(w, span); // {}: all zero
                }
                if entries.len() as u64 != n {
                    return cerr(span, format!("expected {n} elements, found {}", entries.len()));
                }
                let mut es = Vec::new();
                for (_, e) in entries {
                    let v = self.ct_expr(e, Some(et))?;
                    es.push(self.ct_coerce(v, et, span)?);
                }
                Ok(CVal::Array(es, et))
            }
            _ => cerr(span, format!("a {{ }} literal can't make a {} at compile time", self.ty_name(w))),
        }
    }

    /// field access at compile time; `.len`, `.none`/`.value`, and a type's fields are its typeinfo's
    fn ct_field(&mut self, v: CVal, name: &str, span: Span) -> CRes<CVal> {
        match v {
            CVal::Struct(_, fields) => match fields.into_iter().find(|(n, _)| n == name) {
                Some((_, v)) => Ok(v),
                None => cerr(span, format!("no field '{name}'")),
            },
            CVal::Tuple(es) => match name.parse::<usize>().ok().and_then(|i| es.get(i).cloned()) {
                Some(v) => Ok(v),
                None => cerr(span, format!("no field '{name}'")),
            },
            CVal::Str(s) if name == "len" => Ok(CVal::Int(s.len() as i128, USIZE)),
            CVal::Array(es, _) if name == "len" => Ok(CVal::Int(es.len() as i128, USIZE)),
            CVal::Opt(_, v) if name == "none" => Ok(CVal::Bool(v.is_none())),
            CVal::Opt(_, Some(v)) if name == "value" => Ok(*v),
            // a type's fields are its typeinfo's
            CVal::Type(t) => {
                let ti = self.typeinfo(t, span)?;
                self.ct_field(ti, name, span)
            }
            _ => cerr(span, format!("no field '{name}' at compile time")),
        }
    }

    /// runs a block in a scope of its own
    fn ct_block(&mut self, b: &Block) -> CRes<()> {
        self.step(b.span)?; // counts loop iterations even when the body is empty
        self.frame().scopes.push(HashMap::new());
        let r = (|| {
            for s in &b.stmts {
                self.ct_stmt(s)?;
            }
            Ok(())
        })();
        self.frame().scopes.pop();
        r
    }

    /// a let or an expression statement; defer, suspend and resume can't run at compile time
    fn ct_stmt(&mut self, s: &Stmt) -> CRes<()> {
        match &s.kind {
            StmtKind::Let(l) => {
                let env = self.frame().env.clone();
                let ty = match &l.ty {
                    Some(t) if matches!(t.kind, TypeKind::Array(_, None)) => None,
                    Some(t) => Some(self.resolve_type(t, &env)?),
                    None => None,
                };
                let v = match &l.init {
                    Some(e) => {
                        let v = self.ct_expr(e, ty)?;
                        match ty {
                            Some(t) => self.ct_coerce(v, t, e.span)?,
                            None => v,
                        }
                    }
                    None => CVal::Void,
                };
                match &l.pat.kind {
                    PatKind::Bind(n) => {
                        self.frame().scopes.last_mut().unwrap().insert(n.clone(), (v, l.mutable));
                    }
                    PatKind::Tuple(ps) => {
                        let CVal::Tuple(es) = v else { return cerr(l.span, "expected a tuple") };
                        for (p, e) in ps.iter().zip(es) {
                            if let PatKind::Bind(n) = &p.kind {
                                self.frame().scopes.last_mut().unwrap().insert(n.clone(), (e, l.mutable));
                            }
                        }
                    }
                    _ => return cerr(l.span, "unsupported pattern at compile time"),
                }
                Ok(())
            }
            StmtKind::Expr(e) => self.ct_expr(e, None).map(|_| ()),
            _ => cerr(s.span, "defer/suspend/resume don't run at compile time"),
        }
    }

    /// a for loop over a range, list, tuple or string; with an accumulator, its final value is the loop's
    fn ct_for(&mut self, f: &ForLoop, span: Span) -> CRes<CVal> {
        let items = self.ct_items(&f.iter, span)?;
        let mut acc = None;
        if let Some(a) = &f.acc {
            self.frame().scopes.push(HashMap::new());
            self.ct_stmt(&Stmt { kind: StmtKind::Let(a.clone()), span: a.span })?;
            acc = match &a.pat.kind {
                PatKind::Bind(n) => Some(n.clone()),
                _ => None,
            };
        }
        let r = (|| -> CRes<()> {
            for (i, item) in items.into_iter().enumerate() {
                self.frame().scopes.push(HashMap::new());
                let r = (|| -> CRes<()> {
                    let scope = self.frame().scopes.last_mut().unwrap();
                    scope.insert(f.bindings[0].0.clone(), (item, false));
                    if let Some((n, _, _)) = f.bindings.get(1) {
                        scope.insert(n.clone(), (CVal::Int(i as i128, USIZE), false));
                    }
                    if let Some(m) = &f.map {
                        let v = self.ct_expr(m, None)?;
                        self.frame().scopes.last_mut().unwrap().insert(f.bindings[0].0.clone(), (v, false));
                    }
                    self.ct_block(&f.body)
                })();
                self.frame().scopes.pop();
                match r {
                    Ok(()) => {}
                    Err(Ctl::Flow(Flow::Brk(l, _))) if l.is_none() || l == f.label => break,
                    Err(Ctl::Flow(Flow::Cont(l))) if l.is_none() || l == f.label => {}
                    Err(e) => return Err(e),
                }
            }
            Ok(())
        })();
        let out = match &acc {
            Some(n) => self.ct_lookup(n).unwrap_or(CVal::Void),
            None => CVal::Void,
        };
        if f.acc.is_some() {
            self.frame().scopes.pop();
        }
        r.map(|_| out)
    }

    /// what a compile-time for loops over: a range's numbers, an array's or tuple's items, a str's bytes
    fn ct_items(&mut self, iter: &Expr, span: Span) -> CRes<Vec<CVal>> {
        Ok(match &iter.kind {
            ExprKind::Range(Some(lo), Some(hi), incl) => {
                let (CVal::Int(a, t), CVal::Int(b, _)) = (self.ct_expr(lo, None)?, self.ct_expr(hi, None)?) else {
                    return cerr(span, "ranges need integers");
                };
                let end = if *incl { b + 1 } else { b };
                if end - a > 10_000_000 {
                    return cerr(span, "compile-time range is too long");
                }
                (a..end.max(a)).map(|i| CVal::Int(i, t)).collect()
            }
            _ => match self.ct_expr(iter, None)? {
                CVal::Array(es, _) | CVal::Tuple(es) => es,
                CVal::Str(s) => s.into_iter().map(|c| CVal::Int(c as i128, U8)).collect(),
                _ => return cerr(iter.span, "can't loop over this at compile time"),
            },
        })
    }

    /// whether v matches pat, binding names into the current scope
    fn ct_pat(&mut self, pat: &Pat, v: &CVal) -> CRes<bool> {
        Ok(match &pat.kind {
            PatKind::Wild => true,
            PatKind::BindRef(n) => {
                self.frame().scopes.last_mut().unwrap().insert(n.clone(), (v.clone(), false));
                true
            }
            PatKind::Bind(n) => {
                // a bare name that is one of the enum's variants tests for it (as at runtime) instead of binding
                if let CVal::Variant(t, vn, _) = v {
                    if let Some(eid) = self.enum_of(*t) {
                        if self.variant_index(eid, n).is_some() {
                            return Ok(vn == n);
                        }
                    }
                }
                self.frame().scopes.last_mut().unwrap().insert(n.clone(), (v.clone(), false));
                true
            }
            PatKind::Lit(e) => {
                let t = self.ct_type_of(v);
                let lit = self.ct_expr(e, Some(t))?;
                matches!(self.ct_binop(BinOp::Eq, v.clone(), lit, pat.span)?, CVal::Bool(true))
            }
            PatKind::Range(lo, hi, incl) => {
                let (CVal::Int(a, _), CVal::Int(b, _), CVal::Int(x, _)) = (self.ct_expr(lo, None)?, self.ct_expr(hi, None)?, v.clone()) else {
                    return cerr(pat.span, "range patterns need integers");
                };
                x >= a && if *incl { x <= b } else { x < b }
            }
            PatKind::Slice(ps, rest) => {
                let CVal::Array(es, et) = v else { return cerr(pat.span, "slice patterns at compile time match arrays") };
                let n = ps.len();
                if (rest.is_none() && es.len() != n) || es.len() < n {
                    return Ok(false);
                }
                let split = rest.as_ref().map_or(n, |(at, _)| *at);
                for (i, p) in ps.iter().enumerate() {
                    let e = if i < split { &es[i] } else { &es[es.len() - (n - i)] };
                    if !self.ct_pat(p, e)? {
                        return Ok(false);
                    }
                }
                if let Some((at, Some((name, _)))) = rest {
                    let mid = es[*at..es.len() - (n - at)].to_vec();
                    self.frame().scopes.last_mut().unwrap().insert(name.clone(), (CVal::Array(mid, *et), false));
                }
                true
            }
            PatKind::Tuple(ps) => {
                let CVal::Tuple(es) = v else { return Ok(false) };
                if es.len() != ps.len() {
                    return Ok(false);
                }
                for (p, e) in ps.iter().zip(es) {
                    if !self.ct_pat(p, e)? {
                        return Ok(false);
                    }
                }
                true
            }
            PatKind::Ctor(path, args) => {
                let name = match path {
                    CtorPath::Dot(n) => n.clone(),
                    CtorPath::Path(p) => p.last().to_string(),
                };
                let CVal::Variant(_, vn, payload) = v else { return Ok(false) };
                if *vn != name {
                    return Ok(false);
                }
                match (args, payload) {
                    (None, _) => true,
                    (Some(ps), Some(p)) => match (ps.as_slice(), p.as_ref()) {
                        ([one], p) => self.ct_pat(one, p)?,
                        (many, CVal::Tuple(es)) if many.len() == es.len() => {
                            for (sp, e) in many.iter().zip(es) {
                                if !self.ct_pat(sp, e)? {
                                    return Ok(false);
                                }
                            }
                            true
                        }
                        _ => false,
                    },
                    (Some(ps), None) => ps.is_empty(),
                }
            }
        })
    }

    // ---------- calls ----------

    /// a call at compile time: a fn by name (overloads picked by arity, then by return type == want), or an
    /// enum variant with a payload
    fn ct_call_expr(&mut self, callee: &Expr, args: &[Expr], want: Option<TyId>, span: Span) -> CRes<CVal> {
        let ExprKind::Path(p) = &callee.kind else {
            if let ExprKind::DotVariant(n) = &callee.kind {
                let Some(t) = self.dot_target(want) else { return cerr(span, format!("can't tell which enum .{n} belongs to")) };
                let payload = self.ct_payload(args)?;
                return Ok(CVal::Variant(t, n.clone(), payload));
            }
            return cerr(span, "only calls to named functions run at compile time");
        };
        let env = self.frame().env.clone();
        let found = if p.segs.len() == 1 { self.lookup(env.ns, &p.segs[0].name) } else { self.lookup_path_ns(env.ns, p) };
        let decls: Vec<DeclId> = match found {
            Some(Found::Decls(ds)) => ds.into_iter().filter(|d| matches!(self.decls[*d].item.kind, ItemKind::Fn(_))).collect(),
            _ => Vec::new(),
        };
        if decls.is_empty() {
            if let Some(generics::Member::Of(ty, member)) = self.member_path(p)? {
                if self.enum_of(ty).is_some() {
                    let payload = self.ct_payload(args)?;
                    return Ok(CVal::Variant(ty, member, payload));
                }
            }
            return cerr(span, format!("no function '{}' to call at compile time", p.last()));
        }
        let mut vals = Vec::new();
        for a in args {
            vals.push(self.ct_expr(a, None)?);
        }
        // overloads: arity, then return type
        let cands: Vec<DeclId> = decls
            .into_iter()
            .filter(|d| match &self.decls[*d].item.kind {
                ItemKind::Fn(f) => f.params.iter().filter(|p| p.name != "this").count() == vals.len() || f.params.iter().any(|p| p.default.is_some()),
                _ => false,
            })
            .collect();
        let pick = if cands.len() > 1 {
            let mut best = None;
            for d in &cands {
                let item = self.decls[*d].item.clone();
                let ItemKind::Fn(f) = &item.kind else { continue };
                let ns = self.decls[*d].ns;
                let renv = Rc::new(Env { ns, generics: Vec::new() });
                let ret = match &f.ret {
                    Some(r) => self.resolve_type(r, &renv).ok(),
                    None => Some(VOID),
                };
                if want.is_some() && ret == want {
                    best = Some(*d);
                }
            }
            best.or(cands.first().copied())
        } else {
            cands.first().copied()
        };
        let Some(d) = pick else { return cerr(span, format!("no version of '{}' takes {} arguments", p.last(), vals.len())) };
        self.visible(d, span)?;
        let explicit = p.segs.last().unwrap().args.clone().unwrap_or_default();
        self.ct_call(d, &explicit, vals, span)
    }

    /// a variant's payload args: none, one value, or a tuple of several
    fn ct_payload(&mut self, args: &[Expr]) -> CRes<Option<Box<CVal>>> {
        Ok(match args {
            [] => None,
            [one] => Some(Box::new(self.ct_expr(one, None)?)),
            many => {
                let mut es = Vec::new();
                for a in many {
                    es.push(self.ct_expr(a, None)?);
                }
                Some(Box::new(CVal::Tuple(es)))
            }
        })
    }

    /// interprets fn decl on args: binds its generics (explicit, then inferred from the args' types, then
    /// defaults), runs the body in a new frame and coerces the result to the return type
    pub fn ct_call(&mut self, decl: DeclId, explicit: &[GenericArg], args: Vec<CVal>, span: Span) -> CRes<CVal> {
        if self.ct.len() > MAX_DEPTH {
            return cerr(span, "compile-time calls nest too deep (over 256); is there endless recursion?");
        }
        let item = self.decls[decl].item.clone();
        let ItemKind::Fn(f) = &item.kind else { unreachable!() };
        let Some(body) = &f.body else { return cerr(span, format!("'{}' has no body, so it can't run at compile time", f.name)) };
        let ns = self.decls[decl].ns;
        let gps = self.fn_generics(decl);
        let mut binds: Vec<Option<GVal>> = vec![None; gps.len()];
        let caller = self.frame().env.clone();
        for (i, g) in explicit.iter().enumerate() {
            if i < gps.len() {
                let env = self.partial_env(ns, &gps, &binds);
                let kind = self.param_kind(&gps[i], &env)?;
                binds[i] = Some(self.garg_gval(g, kind, &caller)?);
            }
        }
        // infer the rest from the argument values' types, then fall back to defaults
        let vparams: Vec<&Param> = f.params.iter().filter(|p| p.name != "this").collect();
        for (p, v) in vparams.iter().zip(&args) {
            if let Some(pt) = &p.ty {
                let t = self.ct_type_of(v);
                self.infer(pt, t, &gps, &mut binds, ns);
            }
        }
        for i in 0..gps.len() {
            if binds[i].is_none() {
                let env = self.partial_env(ns, &gps, &binds);
                match gps[i].default.clone() {
                    Some(d) => {
                        let kind = self.param_kind(&gps[i], &env)?;
                        binds[i] = Some(self.garg_gval(&d, kind, &env)?);
                    }
                    None => return cerr(span, format!("can't infer '{}' for '{}' at compile time", gps[i].name, f.name)),
                }
            }
        }
        let binds: Vec<GVal> = binds.into_iter().map(Option::unwrap).collect();
        let env = self.inst_env(ns, &gps, &binds);
        // the params, with defaults for missing args, are the new frame's first scope
        let mut scope = HashMap::new();
        for (i, p) in vparams.iter().enumerate() {
            let v = match args.get(i) {
                Some(v) => v.clone(),
                None => match &p.default {
                    Some(d) => self.ct_eval_in(env.clone(), d, None)?,
                    None => return cerr(span, format!("missing argument '{}'", p.name)),
                },
            };
            let v = match &p.ty {
                Some(t) => {
                    let t = self.resolve_type(t, &env)?;
                    self.ct_coerce(v, t, span)?
                }
                None => v,
            };
            scope.insert(p.name.clone(), (v, p.mutable));
        }
        let ret = match &f.ret {
            Some(r) => self.resolve_type(r, &env)?,
            None => VOID,
        };
        self.ct.push(CtFrame { scopes: vec![scope], env });
        let r = self.ct_block(body);
        self.ct.pop();
        let out = match r {
            Ok(()) => CVal::Void,
            Err(Ctl::Flow(Flow::Ret(v))) => v,
            Err(Ctl::Flow(_)) => return cerr(span, "break/continue outside of a loop"),
            Err(e) => return Err(e),
        };
        if ret == VOID || ret == TYPE {
            // a type the call built is named after the call: soa(particle)
            if let CVal::Type(t) = out {
                if self.unnamed_types.contains(&t) {
                    let a: Vec<String> = args.iter().map(|v| self.cval_text(v)).collect();
                    self.name_built(t, format!("{}({})", f.name, a.join(", ")));
                }
            }
            return Ok(out);
        }
        self.ct_coerce(out, ret, span)
    }

    // ---------- types built at compile time ----------

    /// `struct { ... }` / `enum { ... }`: its comptime for and if unrolled, its worked-out names, field
    /// types and enum values evaluated, made a type. The same body seeing the same compile-time values
    /// gives the same type. Its name comes from the call that returns it or the alias it's written in;
    /// until then (or without one) it's named after where it is.
    fn ct_type_body(&mut self, b: &TypeBody, span: Span) -> CRes<CVal> {
        let key = format!("{}:{}|{}", span.file, span.lo, self.frame_values());
        if let Some(t) = self.built_types.get(&key) {
            return Ok(CVal::Type(*t));
        }
        let (mut fields, mut variants) = (Vec::new(), Vec::new());
        self.ct_members(&b.members, &mut fields, &mut variants)?;
        // names are identifiers, each once
        let names: Vec<(String, Span)> = if b.is_enum { variants.iter().map(|v| (v.name.clone(), v.span)).collect() } else { fields.iter().map(|f| (f.name.clone(), f.span)).collect() };
        let what = if b.is_enum { "a variant of this enum" } else { "a field of this struct" };
        for (i, (n, at)) in names.iter().enumerate() {
            let ok = n.chars().next().is_some_and(|c| c.is_ascii_alphabetic() || c == '_') && n.chars().all(|c| c.is_ascii_alphanumeric() || c == '_');
            if !ok {
                return cerr(*at, format!("'{n}' isn't a name: a letter or _, then letters, digits and _"));
            }
            if crate::parser::KEYWORDS.contains(&n.as_str()) {
                return cerr(*at, format!("'{n}' is a keyword, so it can't be a name"));
            }
            if names[..i].iter().any(|(m, _)| m == n) {
                return cerr(*at, format!("'{n}' is already {what}"));
            }
        }
        let env = self.frame().env.clone();
        let line = self.loc(span);
        let base = if b.is_enum { "enum" } else { "struct" };
        let kind = if b.is_enum {
            ItemKind::Enum(EnumDecl { name: base.into(), backing: b.backing.clone(), variants, is_error: false })
        } else {
            ItemKind::Struct(StructDecl { name: base.into(), spec: None, fields, is_extern: false, is_comptime: false, c_name: None, c_union: false })
        };
        let item = Item { kind, span, attrs: Vec::new(), vis: Vis::Public, generics: Vec::new() };
        let decl = self.decls.len();
        self.decls.push(Decl { item: Rc::new(item), ns: env.ns, file: span.file, parent: None });
        let t = if b.is_enum { self.enum_inst(decl, Vec::new(), span)? } else { self.struct_inst(decl, Vec::new(), span)? };
        self.built_types.insert(key, t);
        self.unnamed_types.insert(t);
        self.set_type_name(t, format!("{base} at {line}"));
        Ok(CVal::Type(t))
    }

    /// what a type body sees at compile time, as a memo key: its frame's locals and generic arguments
    fn frame_values(&mut self) -> String {
        let f = self.ct.last().unwrap();
        let mut parts: Vec<String> = f.scopes.iter().flat_map(|s| s.iter().map(|(n, (v, _))| format!("{n}={}", self.cval_key(v)))).collect();
        parts.sort();
        parts.extend(f.env.generics.iter().map(|(n, g)| match g {
            GVal::Ty(t) => format!("{n}:#{t}"),
            GVal::Pack(ts) => format!("{n}:#{}", ts.iter().map(|t| t.to_string()).collect::<Vec<_>>().join(",#")),
            _ => format!("{n}:{}", self.gval_name(g)),
        }));
        parts.join(";")
    }

    /// a value as a memo key: types by identity (two can have one name, and a built one's name changes),
    /// numbers with their types, strs with their length
    fn cval_key(&self, v: &CVal) -> String {
        let list = |c: &Self, vs: &[CVal]| vs.iter().map(|x| c.cval_key(x)).collect::<Vec<_>>().join(",");
        match v {
            CVal::Type(t) => format!("#{t}"),
            CVal::Int(n, t) => format!("{n}#{t}"),
            CVal::Float(x, t) => format!("{x}#{t}"),
            CVal::Str(s) => format!("{}:{}", s.len(), String::from_utf8_lossy(s)),
            CVal::Tuple(vs) => format!("({})", list(self, vs)),
            CVal::Array(vs, t) => format!("[{}]#{t}", list(self, vs)),
            CVal::Struct(t, fs) => format!("{{#{t} {}}}", fs.iter().map(|(n, x)| format!("{n}={}", self.cval_key(x))).collect::<Vec<_>>().join(",")),
            CVal::Variant(t, n, p) => format!("{n}#{t}({})", p.as_ref().map(|x| self.cval_key(x)).unwrap_or_default()),
            CVal::Opt(t, x) => format!("?#{t}({})", x.as_ref().map(|x| self.cval_key(x)).unwrap_or_default()),
            other => self.cval_text(other),
        }
    }

    /// a body's members, unrolled: a comptime for runs its members once per item (its variables bound
    /// in a new scope), a comptime if takes one branch, and a worked-out name becomes its str. Field
    /// types and enum values are evaluated now, so they can use the loop variables; so are defaults
    /// that are numbers, bools or strs
    fn ct_members(&mut self, ms: &[Member], fields: &mut Vec<Field>, variants: &mut Vec<Variant>) -> CRes<()> {
        for m in ms {
            match m {
                Member::Field(f, named) => {
                    let mut f = f.clone();
                    if let Some(e) = named {
                        f.name = self.ct_name(e)?;
                    }
                    let t = self.ct_type(&f.ty)?;
                    f.ty = Type { kind: TypeKind::Resolved(t), span: f.ty.span };
                    if let Some(d) = &f.default {
                        if let Ok(v) = self.ct_expr(d, Some(t)) {
                            if let Some(e) = Self::cval_expr(&v, d.span) {
                                f.default = Some(e);
                            }
                        }
                    }
                    fields.push(f);
                }
                Member::Variant(v, named) => {
                    let mut v = v.clone();
                    if let Some(e) = named {
                        v.name = self.ct_name(e)?;
                    }
                    if let Some(p) = &v.payload {
                        let t = self.ct_type(p)?;
                        v.payload = Some(Type { kind: TypeKind::Resolved(t), span: p.span });
                    }
                    if let Some(x) = &v.value {
                        let val = self.ct_expr(x, None)?;
                        if !matches!(val, CVal::Int(..)) {
                            return cerr(x.span, "an enum value is a number");
                        }
                        v.value = Self::cval_expr(&val, x.span);
                    }
                    variants.push(v);
                }
                Member::For { bindings, iter, body, .. } => {
                    for (i, item) in self.ct_items(iter, iter.span)?.into_iter().enumerate() {
                        let mut scope = HashMap::new();
                        scope.insert(bindings[0].0.clone(), (item, false));
                        if let Some((n, _, _)) = bindings.get(1) {
                            scope.insert(n.clone(), (CVal::Int(i as i128, USIZE), false));
                        }
                        self.frame().scopes.push(scope);
                        let r = self.ct_members(body, fields, variants);
                        self.frame().scopes.pop();
                        r?;
                    }
                }
                Member::If { cond, then, els, .. } => {
                    let pick = match self.ct_expr(cond, Some(BOOL))? {
                        CVal::Bool(b) => b,
                        _ => return cerr(cond.span, "comptime if needs a bool"),
                    };
                    self.ct_members(if pick { then } else { els }, fields, variants)?;
                }
            }
        }
        Ok(())
    }

    /// a worked-out name: the str an expression gives
    fn ct_name(&mut self, e: &Expr) -> CRes<String> {
        match self.ct_expr(e, Some(STR))? {
            CVal::Str(s) => Ok(String::from_utf8_lossy(&s).into_owned()),
            v => {
                let t = self.ct_type_of(&v);
                cerr(e.span, format!("a computed name is a str, found {}", self.ty_name(t)))
            }
        }
    }

    /// a number, bool or str as the literal that writes it
    fn cval_expr(v: &CVal, span: Span) -> Option<Expr> {
        let kind = match v {
            CVal::Int(n, _) if *n < 0 => ExprKind::Unary(UnOp::Neg, Box::new(Expr { kind: ExprKind::Int(n.unsigned_abs() as u128 as _), span })),
            CVal::Int(n, _) => ExprKind::Int(*n as _),
            CVal::Float(f, _) => ExprKind::Float(*f),
            CVal::Bool(b) => ExprKind::Bool(*b),
            CVal::Str(s) => ExprKind::Str(s.clone()),
            _ => return None,
        };
        Some(Expr { kind, span })
    }

    /// a type written in a type body, its expressions (std::vec<f.field_type>, pick(x)) evaluated in
    /// this frame, so they see its locals
    fn ct_type(&mut self, t: &Type) -> CRes<TyId> {
        let t = self.ct_subst(t)?;
        let env = self.frame().env.clone();
        Ok(self.resolve_type(&t, &env)?)
    }

    fn ct_subst(&mut self, t: &Type) -> CRes<Type> {
        let sub = |c: &mut Self, x: &Type| c.ct_subst(x).map(Box::new);
        let kind = match &t.kind {
            TypeKind::Expr(e) => match self.ct_expr(e, Some(TYPE))? {
                CVal::Type(r) => TypeKind::Resolved(r),
                _ => return cerr(e.span, "this doesn't give a type"),
            },
            TypeKind::Path(p) => {
                let mut p = p.clone();
                for seg in &mut p.segs {
                    for a in seg.args.iter_mut().flatten() {
                        *a = match a.clone() {
                            GenericArg::Type(x) => GenericArg::Type(self.ct_subst(&x)?),
                            // a value the frame can work out (a type, a number); else as written
                            GenericArg::Expr(e) => match self.ct_expr(&e, None) {
                                Ok(CVal::Type(r)) => GenericArg::Type(Type { kind: TypeKind::Resolved(r), span: e.span }),
                                Ok(v) => Self::cval_expr(&v, e.span).map(GenericArg::Expr).unwrap_or(GenericArg::Expr(e)),
                                Err(_) => GenericArg::Expr(e),
                            },
                        };
                    }
                }
                TypeKind::Path(p)
            }
            TypeKind::Ref(i) => TypeKind::Ref(sub(self, i)?),
            TypeKind::Ptr(i) => TypeKind::Ptr(sub(self, i)?),
            TypeKind::Optional(i) => TypeKind::Optional(sub(self, i)?),
            TypeKind::Slice(i) => TypeKind::Slice(sub(self, i)?),
            TypeKind::Array(i, n) => TypeKind::Array(sub(self, i)?, n.clone()),
            TypeKind::Tuple(es) => {
                let mut out = Vec::new();
                for (n, x) in es {
                    out.push((n.clone(), self.ct_subst(x)?));
                }
                TypeKind::Tuple(out)
            }
            other => other.clone(),
        };
        Ok(Type { kind, span: t.span })
    }

    /// a built type gets its shown name (from its call or alias), once
    pub fn name_built(&mut self, t: TyId, name: String) {
        if self.unnamed_types.remove(&t) {
            self.set_type_name(t, name);
        }
    }

    fn set_type_name(&mut self, t: TyId, name: String) {
        match self.t.get(t).clone() {
            Ty::Struct(s) => self.structs[s as usize].name = name,
            Ty::Enum(e) => self.enums[e as usize].name = name,
            _ => {}
        }
    }

    // ---------- builtins ----------

    /// @typeinfo, @typeid, @typeof, @compile_error, @cfg, @attaches, @sizeof, @alignof, @cast and @panic at compile time
    fn ct_builtin(&mut self, name: &str, gargs: &[GenericArg], args: &[GenericArg], want: Option<TyId>, span: Span) -> CRes<CVal> {
        let env = self.frame().env.clone();
        let ty_arg = |c: &mut Self, g: &GenericArg| -> CRes<TyId> {
            match g {
                GenericArg::Expr(e) if !matches!(e.kind, ExprKind::Path(_)) => match c.ct_expr(e, None)? {
                    CVal::Type(t) => Ok(t),
                    _ => cerr(e.span, "expected a type"),
                },
                _ => {
                    // a comptime variable holding a type, or a type written out
                    if let GenericArg::Expr(Expr { kind: ExprKind::Path(p), .. }) | GenericArg::Type(Type { kind: TypeKind::Path(p), .. }) = g {
                        if p.is_single() {
                            if let Some(CVal::Type(t)) = c.ct_lookup(&p.segs[0].name) {
                                return Ok(t);
                            }
                        }
                    }
                    Ok(c.garg_type_env(g, &env)?)
                }
            }
        };
        match name {
            "typeinfo" => {
                let [g] = args else { return cerr(span, "@typeinfo(T) takes one type") };
                let t = ty_arg(self, g)?;
                Ok(self.typeinfo(t, span)?)
            }
            "typeid" => {
                let [g] = args else { return cerr(span, "@typeid takes one type or value") };
                let t = match ty_arg(self, g) {
                    Ok(t) => t,
                    // a compile-time value: its type's id
                    Err(_) => {
                        let v = self.ct_expr(&Self::garg_value(g)?, None)?;
                        self.ct_type_of(&v)
                    }
                };
                Ok(CVal::Int(self.type_id(t) as i128, int(IntTy::U64)))
            }
            "typeof" => {
                let [g] = args else { return cerr(span, "@typeof(x) takes one value") };
                let e = match g {
                    GenericArg::Expr(e) => e.clone(),
                    GenericArg::Type(Type { kind: TypeKind::Path(p), span }) => Expr { kind: ExprKind::Path(p.clone()), span: *span },
                    GenericArg::Type(t) => return cerr(t.span, "expected a value"),
                };
                // compile-time values have types; runtime expressions are type checked (not run)
                if self.ct.len() == 1 && !self.is_ct_expr(&e) {
                    if let ExprKind::Path(p) = &e.kind {
                        if p.is_single() && self.ct_lookup(&p.segs[0].name).is_none() {
                            if let Some(l) = self.lookup_local(&p.segs[0].name) {
                                return Ok(CVal::Type(l.ty));
                            }
                        }
                    }
                }
                let v = self.ct_expr(&e, None)?;
                Ok(CVal::Type(self.ct_type_of(&v)))
            }
            "compile_error" => {
                let msg = match args.first() {
                    Some(GenericArg::Expr(e)) => match self.ct_expr(e, None)? {
                        CVal::Str(s) => String::from_utf8_lossy(&s).into_owned(),
                        _ => "compile error".into(),
                    },
                    _ => "compile error".into(),
                };
                cerr(span, msg)
            }
            "cfg" => {
                // @cfg(KEY) / @cfg(KEY, VALUE): was --cfg KEY[=VALUE] given for the package this is written in,
                // or is it one of the target's keys (os, arch, pointer_bits)?
                let mut parts = Vec::new();
                for a in args {
                    match a {
                        GenericArg::Expr(e) => match self.ct_expr(e, None)? {
                            CVal::Str(s) => parts.push(String::from_utf8_lossy(&s).into_owned()),
                            _ => return cerr(e.span, "@cfg takes strings: @cfg(\"feature\", \"name\")"),
                        },
                        GenericArg::Type(t) => return cerr(t.span, "@cfg takes strings: @cfg(\"feature\", \"name\")"),
                    }
                }
                Ok(CVal::Bool(self.cfg_on(&parts, span)?))
            }
            "attaches" => {
                // @attaches(T, some_trait): does T attach the trait (as a <T: some_trait> bound asks)?
                let [g, tr] = args else { return cerr(span, "@attaches(T, trait) takes a type and a trait") };
                let t = ty_arg(self, g)?;
                let bound = match tr {
                    GenericArg::Type(b) => b.clone(),
                    GenericArg::Expr(Expr { kind: ExprKind::Path(p), span }) => Type { kind: TypeKind::Path(p.clone()), span: *span },
                    GenericArg::Expr(e) => return cerr(e.span, "@attaches(T, trait): expected a trait"),
                };
                let Some((d, targs)) = self.bound_trait(&bound, env.ns) else { return cerr(bound.span, "@attaches(T, trait): expected a trait") };
                Ok(CVal::Bool(self.satisfies(t, d, &targs, &env)?))
            }
            "has_method" => {
                // @has_method(T, "name", A...): does T have a method of that name (attached to it, by
                // an attach fn or an attach block), taking arguments of types A first?
                let [g, n, rest @ ..] = args else { return cerr(span, "@has_method(T, \"name\", A...) takes a type, a name and argument types") };
                let t = ty_arg(self, g)?;
                let name = match n {
                    GenericArg::Expr(e) => match self.ct_expr(e, None)? {
                        CVal::Str(s) => String::from_utf8_lossy(&s).into_owned(),
                        _ => return cerr(e.span, "@has_method(T, \"name\"): the name is a string"),
                    },
                    GenericArg::Type(t) => return cerr(t.span, "@has_method(T, \"name\"): the name is a string"),
                };
                let mut tys = vec![];
                for a in rest {
                    tys.push(ty_arg(self, a)?);
                }
                Ok(CVal::Bool(self.has_method(t, &name, &tys)))
            }
            "has_field" => {
                // @has_field(T, "name"): is T a struct with a field of that name?
                let [g, n] = args else { return cerr(span, "@has_field(T, \"name\") takes a type and a name") };
                let t = ty_arg(self, g)?;
                let name = match n {
                    GenericArg::Expr(e) => match self.ct_expr(e, None)? {
                        CVal::Str(s) => String::from_utf8_lossy(&s).into_owned(),
                        _ => return cerr(e.span, "@has_field(T, \"name\"): the name is a string"),
                    },
                    GenericArg::Type(t) => return cerr(t.span, "@has_field(T, \"name\"): the name is a string"),
                };
                let has = match self.t.get(t).clone() {
                    Ty::Struct(sid) => self.struct_fields(sid, span)?.iter().any(|f| f.name == name),
                    _ => false,
                };
                Ok(CVal::Bool(has))
            }
            "sizeof" | "alignof" => {
                let [g] = args else { return cerr(span, format!("@{name}(T) takes one type")) };
                let t = ty_arg(self, g)?;
                let (size, align) = self.layout(t, span)?;
                Ok(CVal::Int(if name == "sizeof" { size } else { align } as i128, USIZE))
            }
            "cast" => {
                let ([g], [a]) = (gargs, args) else { return cerr(span, "@cast<T>(x)") };
                let to = self.garg_type_env(g, &env)?;
                let v = match a {
                    GenericArg::Expr(e) => self.ct_expr(e, None)?,
                    GenericArg::Type(Type { kind: TypeKind::Path(p), span }) => self.ct_path(p, None, *span)?,
                    GenericArg::Type(t) => return cerr(t.span, "expected a value"),
                };
                self.ct_convert(v, to, true, span)
            }
            "panic" => cerr(span, "@panic reached at compile time"),
            _ => {
                let _ = want;
                cerr(span, format!("@{name} doesn't run at compile time"))
            }
        }
    }

    // ---------- typeinfo + layout ----------

    /// a comptime-only record, like a typeinfo
    fn rec(fields: Vec<(&str, CVal)>) -> CVal {
        CVal::Struct(VOID, fields.into_iter().map(|(n, v)| (n.to_string(), v)).collect())
    }

    /// a typeinfo kind (a variant of no real enum)
    fn kind(name: &str, payload: Option<CVal>) -> CVal {
        CVal::Variant(VOID, name.into(), payload.map(Box::new))
    }

    /// the @typeinfo record of t: its names, kind (with the kind's details), layout, generic args and so on
    pub fn typeinfo(&mut self, t: TyId, span: Span) -> Res<CVal> {
        let full = self.ty_name(t);
        let base = full.split('<').next().unwrap_or(&full).to_string();
        let short = base.rsplit("::").next().unwrap_or(&base).to_string();
        let module = base.rsplit_once("::").map(|x| x.0.to_string()).unwrap_or_default();
        // an Opt value carries the optional type (usize?), not its payload's
        let (opt_usize_ty, opt_str, opt_i64, opt_type) =
            (self.t.intern(Ty::Opt(USIZE)), self.t.intern(Ty::Opt(STR)), self.t.intern(Ty::Opt(I64)), self.t.intern(Ty::Opt(TYPE)));
        let opt_usize = |v: Option<u64>| CVal::Opt(opt_usize_ty, v.map(|x| Box::new(CVal::Int(x as i128, USIZE))));
        let (size, align) = match self.layout(t, span) {
            Ok((s, a)) if t != VOID => (Some(s), Some(a)),
            _ => (None, None),
        };
        let types = |ts: &[TyId]| CVal::Array(ts.iter().map(|x| CVal::Type(*x)).collect(), TYPE);
        let kind = match self.t.get(t).clone() {
            Ty::Void => Self::kind("VOID", None),
            Ty::Never => Self::kind("NEVER", None),
            Ty::Bool => Self::kind("BOOL", None),
            Ty::TypeTy => Self::kind("TYPE", None),
            Ty::Int(k) => Self::kind("INT", Some(CVal::Tuple(vec![CVal::Bool(k.signed()), CVal::Int(k.bits() as i128, int(IntTy::U16))]))),
            Ty::Float(b) => Self::kind("FLOAT", Some(CVal::Int(b as i128, int(IntTy::U16)))),
            Ty::Ref(c) => Self::kind("REFERENCE", Some(CVal::Type(c))),
            Ty::Ptr(c) => Self::kind("POINTER", Some(CVal::Type(c))),
            Ty::Array(c, n) => Self::kind("ARRAY", Some(CVal::Tuple(vec![CVal::Type(c), CVal::Int(n as i128, USIZE)]))),
            Ty::Slice(c) => Self::kind("SLICE", Some(CVal::Type(c))),
            Ty::Str => Self::kind("SLICE", Some(CVal::Type(U8))),
            Ty::Opt(c) => Self::kind("OPTIONAL", Some(CVal::Type(c))),
            Ty::ErrUnion(e, p) => Self::kind("ERROR_UNION", Some(CVal::Tuple(vec![CVal::Type(e), CVal::Type(p)]))),
            Ty::Range(c) => Self::kind("RANGE", Some(CVal::Type(c))),
            Ty::Tuple(ts, _) => Self::kind("TUPLE", Some(types(&ts))),
            Ty::Struct(sid) => {
                let fields = self.struct_fields(sid, span)?;
                let env = self.structs[sid as usize].env.clone();
                let decl_fields = match &self.decls[self.structs[sid as usize].decl].item.kind {
                    ItemKind::Struct(sd) => sd.fields.clone(),
                    _ => Vec::new(),
                };
                let mut out = Vec::new();
                let mut off = 0u64;
                for f in fields.iter() {
                    let (s, a) = self.layout(f.ty, span)?;
                    off = off.div_ceil(a.max(1)) * a.max(1);
                    let attrs = match decl_fields.iter().find(|d| d.name == f.name) {
                        Some(d) => self.user_attrs(&d.attrs, &env)?,
                        None => CVal::Tuple(Vec::new()),
                    };
                    out.push(Self::rec(vec![
                        ("name", CVal::Str(f.name.clone().into_bytes())),
                        ("field_type", CVal::Type(f.ty)),
                        ("offset", opt_usize(Some(off))),
                        ("default_expr", CVal::Opt(opt_str, None)),
                        ("visibility", Self::kind("PUBLIC", None)),
                        ("attributes", attrs),
                    ]));
                    off += s;
                }
                Self::kind("STRUCT", Some(CVal::Tuple(vec![CVal::Array(out, VOID), Self::kind("C", None)])))
            }
            Ty::Enum(e) => {
                let payloads = self.enum_payloads(e, span)?;
                let info = &self.enums[e as usize];
                let (names, values, tag, is_error) = (info.names.clone(), info.values.clone(), info.tag, info.is_error);
                let vars: Vec<CVal> = names
                    .iter()
                    .enumerate()
                    .map(|(i, n)| {
                        Self::rec(vec![
                            ("name", CVal::Str(n.clone().into_bytes())),
                            ("discriminant", CVal::Opt(opt_i64, Some(Box::new(CVal::Int(values[i], I64))))),
                            ("payload", match payloads[i] {
                                Some(p) => CVal::Opt(opt_type, Some(Box::new(CVal::Type(p)))),
                                None => CVal::Opt(opt_type, None),
                            }),
                            ("attributes", CVal::Array(Vec::new(), VOID)),
                        ])
                    })
                    .collect();
                if is_error {
                    Self::kind("ERROR_SET", Some(CVal::Array(vars, VOID)))
                } else {
                    Self::kind("ENUM", Some(CVal::Tuple(vec![CVal::Type(int(tag)), CVal::Array(vars, VOID)])))
                }
            }
            Ty::FnPtr(ps, r, _) | Ty::FnVal(ps, r) => Self::kind(
                "FUNCTION",
                Some(CVal::Tuple(vec![types(&ps), CVal::Type(r), CVal::Bool(false), CVal::Bool(false), CVal::Str(b"C".to_vec())])),
            ),
            Ty::Closure(c) => {
                let caps = self.closures[c as usize].caps.clone();
                Self::kind("CLOSURE", Some(CVal::Array(caps.iter().map(|x| CVal::Type(x.1)).collect(), TYPE)))
            }
            Ty::TraitUnion(u) => {
                let (n, m) = (self.unions[u as usize].name.clone(), self.unions[u as usize].members.clone());
                Self::kind("TRAIT_UNION", Some(CVal::Tuple(vec![CVal::Str(n.into_bytes()), types(&m)])))
            }
            _ => Self::kind("UNKNOWN", None),
        };
        let generic_args = match self.t.get(t) {
            Ty::Struct(s) => self.structs[*s as usize].args.clone(),
            Ty::Enum(e) => self.enums[*e as usize].args.clone(),
            _ => Vec::new(),
        };
        let gargs: Vec<CVal> = generic_args
            .iter()
            .map(|g| match g {
                GVal::Ty(t) => CVal::Type(*t),
                GVal::Int(v) => CVal::Int(*v, VOID),
                GVal::Str(s) => CVal::Str(s.clone()),
                GVal::Pack(ts) => CVal::Tuple(ts.iter().map(|t| CVal::Type(*t)).collect()),
            })
            .collect();
        let is_pod = !self.needs_drop(t)?;
        // a struct's or enum's library attributes
        let attributes = match self.t.get(t).clone() {
            Ty::Struct(s) => {
                let (d, env) = (self.structs[s as usize].decl, self.structs[s as usize].env.clone());
                let attrs = self.decls[d].item.attrs.clone();
                self.user_attrs(&attrs, &env)?
            }
            Ty::Enum(e) => {
                let (d, env) = (self.enums[e as usize].decl, self.enums[e as usize].env.clone());
                let attrs = self.decls[d].item.attrs.clone();
                self.user_attrs(&attrs, &env)?
            }
            _ => CVal::Tuple(Vec::new()),
        };
        // the kind's fields or variants, also right on the record (empty for other kinds), so a
        // comptime for can loop over them without matching the kind
        let part = |name: &str, i: usize| match &kind {
            CVal::Variant(_, n, Some(p)) if n == name => match p.as_ref() {
                CVal::Tuple(xs) => xs.get(i).cloned(),
                x => Some(x.clone()),
            },
            _ => None,
        };
        let none = CVal::Array(Vec::new(), VOID);
        let fields = part("STRUCT", 0).unwrap_or_else(|| none.clone());
        let variants = part("ENUM", 1).or_else(|| part("ERROR_SET", 0)).unwrap_or(none);
        Ok(Self::rec(vec![
            ("id", CVal::Int(t as i128, int(IntTy::U128))),
            ("canonical_name", CVal::Str(full.into_bytes())),
            ("short_name", CVal::Str(short.into_bytes())),
            ("module_path", CVal::Str(module.into_bytes())),
            ("kind", kind.clone()),
            ("fields", fields),
            ("variants", variants),
            ("size", opt_usize(size)),
            ("align", opt_usize(align)),
            ("stride", opt_usize(size)),
            ("is_pod", CVal::Bool(is_pod)),
            ("is_comptime_only", CVal::Bool(t == TYPE)),
            ("generic_args", CVal::Array(gargs, VOID)),
            ("visibility", Self::kind("PUBLIC", None)),
            ("attributes", attributes),
        ]))
    }

    /// size and alignment as the C compiler lays things out (x86_64 SysV)
    // ponytail: one target's rules; add a target table when voltc cross-compiles
    pub fn layout(&mut self, t: TyId, span: Span) -> Res<(u64, u64)> {
        let rec = |c: &mut Self, ts: &[TyId]| -> Res<(u64, u64)> {
            let (mut off, mut al) = (0u64, 1u64);
            for t in ts {
                let (s, a) = c.layout(*t, span)?;
                off = off.div_ceil(a) * a + s;
                al = al.max(a);
            }
            Ok((off.div_ceil(al) * al, al))
        };
        Ok(match self.t.get(t).clone() {
            // only fields Volt could read were imported, so only C knows the real layout
            Ty::Struct(s) if self.header_struct(s) => return err(span, format!("C struct {} has no compile-time layout; @sizeof works on it at runtime", self.ty_name(t))),
            Ty::Void | Ty::Never => (0, 1),
            Ty::Bool => (1, 1),
            Ty::Int(k) => {
                let b = (k.bits() / 8) as u64;
                (b, b)
            }
            Ty::Float(b) => ((b / 8) as u64, (b / 8) as u64),
            Ty::Ref(_) | Ty::Ptr(_) | Ty::VoidPtr | Ty::CStr | Ty::Null | Ty::FnPtr(..) => (8, 8),
            Ty::AnyErr => (4, 4), // a uint32_t code
            Ty::Str | Ty::Slice(_) | Ty::FnVal(..) => (16, 8),
            Ty::Opt(i) if self.t.is_niche(i) => (8, 8),
            Ty::Opt(i) if self.niche_field(i).is_some() => self.layout(i, span)?,
            Ty::Opt(i) => rec(self, &[i, BOOL])?,
            Ty::Array(e, n) => {
                let (s, a) = self.layout(e, span)?;
                (s * n, a)
            }
            Ty::Tuple(ts, _) => rec(self, &ts)?,
            Ty::Range(e) => rec(self, &[e, e])?,
            Ty::Struct(sid) => {
                let fs: Vec<TyId> = self.struct_fields(sid, span)?.iter().map(|f| f.ty).collect();
                rec(self, &fs)?
            }
            Ty::Enum(e) => {
                let tag = int(self.enums[e as usize].tag);
                if !self.enums[e as usize].has_payload {
                    return self.layout(tag, span);
                }
                let (mut us, mut ua) = (0, 1);
                for p in self.enum_payloads(e, span)?.iter().flatten() {
                    let (s, a) = self.layout(*p, span)?;
                    us = us.max(s);
                    ua = ua.max(a);
                }
                let (ts, ta) = self.layout(tag, span)?;
                let off = ts.div_ceil(ua) * ua;
                let al = ta.max(ua);
                ((off + us.div_ceil(ua) * ua).div_ceil(al) * al, al)
            }
            Ty::ErrUnion(e, p) => rec(self, &[e, p])?,
            Ty::TraitUnion(u) => {
                let (mut us, mut ua) = (0, 1);
                for m in self.unions[u as usize].members.clone() {
                    let (s, a) = self.layout(m, span)?;
                    us = us.max(s);
                    ua = ua.max(a);
                }
                let off = 2u64.div_ceil(ua) * ua;
                let al = ua.max(2);
                ((off + us).div_ceil(al) * al, al)
            }
            Ty::Closure(c) => {
                let ts: Vec<TyId> = self.closures[c as usize].caps.iter().map(|x| x.1).collect();
                if ts.is_empty() { (1, 1) } else { rec(self, &ts)? }
            }
            Ty::TypeTy | Ty::Frame(_) => return err(span, format!("{} has no runtime size", self.ty_name(t))),
        })
    }
}

impl Checker {
    /// comptime match inside a runtime fn: pick the arm now, check only its body
    pub fn ct_match(&mut self, scrut: &Expr, arms: &[Arm], want: Option<TyId>, span: Span) -> Res<Val> {
        let v = self.ct_eval(scrut, None)?;
        for arm in arms {
            let env = self.cx.env.clone();
            self.ct.push(CtFrame { scopes: vec![HashMap::new()], env });
            let hit = (|| -> CRes<bool> {
                if !self.ct_pat(&arm.pat, &v)? {
                    return Ok(false);
                }
                match &arm.guard {
                    Some(g) => self.ct_bool(g),
                    None => Ok(true),
                }
            })();
            let binds = self.ct.pop().unwrap().scopes.pop().unwrap();
            let hit = match hit {
                Ok(h) => h,
                Err(Ctl::Err(d)) => return Err(d),
                Err(Ctl::Flow(_)) => return err(arm.span, "can't leave a comptime match pattern"),
            };
            if hit {
                let mut scope = Scope::default();
                scope.consts = binds;
                self.cx.scopes.push(scope);
                let r = self.expr(&arm.body, want);
                self.cx.scopes.pop();
                return r;
            }
        }
        err(span, "no comptime match arm matched")
    }

    /// comptime for: unrolled at compile time. Over a compile-time list, the loop variable is a
    /// constant; over a runtime tuple (a pack like args), each copy sees one element with its own type.
    pub fn ct_for_unroll(&mut self, f: &ForLoop, span: Span) -> Res<Val> {
        let name = f.bindings[0].0.clone();
        let li = {
            let id = self.tmp("");
            self.cx.loops.push(LoopCx {
                label: f.label.clone(),
                is_block: false,
                brk: format!("brk{id}"),
                cont: Some(format!("cont{id}")),
                result: None,
                break_ty: None,
                has_break: false,
                depth: self.cx.scopes.len(),
                moved_at_break: Default::default(),
                moved_at_entry: self.cx.moved.clone(),
            });
            self.cx.loops.len() - 1
        };
        let r = (|| -> Res<String> {
            let mut code = String::new();
            let runtime = match &f.iter.kind {
                ExprKind::Range(..) => None,
                _ if self.is_ct_expr(&f.iter) => None,
                _ => Some(self.expr(&f.iter, None)?),
            };
            let items: Vec<(Option<comptime::CVal>, Option<(TyId, String)>)> = match &runtime {
                Some(v) => match self.t.get(v.ty).clone() {
                    Ty::Tuple(ts, _) => {
                        // the tuple is read once per element, so keep it in a temp
                        let tu = self.slot("_tu", v.ty);
                        let tc = self.cty(v.ty);
                        code.push_str(&format!("{}; ", Self::decl(&tc, &tu, &v.c)));
                        ts.iter().enumerate().map(|(i, t)| (None, Some((*t, format!("({tu}).f{i}"))))).collect()
                    }
                    Ty::Void => Vec::new(), // an empty pack
                    _ => return err(f.iter.span, "comptime for loops over a tuple, pack, range or compile-time list"),
                },
                None => {
                    let list = match &f.iter.kind {
                        ExprKind::Range(Some(lo), Some(hi), incl) => {
                            let env = self.cx.env.clone();
                            let (a, b) = (self.const_int(lo, &env)?, self.const_int(hi, &env)?);
                            (a..if *incl { b + 1 } else { b }).map(|i| CVal::Int(i, VOID)).collect()
                        }
                        _ => match self.ct_eval(&f.iter, None)? {
                            CVal::Array(es, _) | CVal::Tuple(es) => es,
                            _ => return err(f.iter.span, "comptime for needs a list it can see at compile time"),
                        },
                    };
                    list.into_iter().map(|v| (Some(v), None)).collect()
                }
            };
            let base_cont = self.cx.loops[li].cont.clone().unwrap();
            for (i, (cv, rv)) in items.into_iter().enumerate() {
                let cont = format!("{base_cont}_{i}");
                self.cx.loops[li].cont = Some(cont.clone());
                let mut scope = Scope::default();
                let mut bind = String::new();
                match (cv, rv) {
                    (Some(v), _) => {
                        scope.consts.insert(name.clone(), (v, false));
                    }
                    (None, Some((t, c))) => {
                        self.cx.next_id += 1;
                        let local = format!("{name}_{}", self.cx.next_id);
                        let tc = self.cty(t);
                        bind = format!("{tc} {local} = {c}; ");
                        scope.vars.insert(name.clone(), Local { c: local, ty: t, mutable: false, orig: None, flag: None, loops: 0, ro: 0, via: None, root: None, param: false, own: None });
                    }
                    _ => unreachable!(),
                }
                if let Some((iname, _, _)) = f.bindings.get(1) {
                    scope.consts.insert(iname.clone(), (CVal::Int(i as i128, USIZE), false));
                }
                self.cx.scopes.push(scope);
                let r = self.block_code(&f.body);
                self.cx.scopes.pop();
                let (body, _) = r?;
                code.push_str(&format!("{{ {bind}{body} {cont}:; }}\n"));
            }
            Ok(code)
        })();
        let lc = self.cx.loops.pop().unwrap();
        let code = r?;
        let _ = span;
        Ok(Val::new(VOID, format!("{{ {code} {}:; }}", lc.brk)))
    }
}

// ---------- attributes ----------

/// the attributes that exist (enum attribute in the spec); @intrinsic is for packages (a std, or
/// any library) to bind compiler-provided functions like println
const ATTRS: &[(&str, usize)] = &[("inline", 0), ("noinline", 0), ("opt", 1), ("section", 1), ("align", 1), ("deprecated", 1), ("owns", 1), ("cpp_type", 1), ("export_text", 1), ("thread_local", 0), ("cfg", 2), ("optional", 0), ("closed", 0), ("attach_as", 1), ("derive", 1)];

/// an attribute's string argument: @owns("ptr") -> ptr
pub fn attr_str(a: &Expr) -> Option<String> {
    match &a.kind {
        ExprKind::Builtin(_, _, Some(args)) => match args.first()? {
            GenericArg::Expr(Expr { kind: ExprKind::Str(s), .. }) => Some(String::from_utf8_lossy(s).into_owned()),
            _ => None,
        },
        _ => None,
    }
}

impl Checker {
    /// @cfg(KEY) / @cfg(KEY, VALUE), as a builtin or an item's attribute: was --cfg KEY[=VALUE] given for
    /// the package the code at span is in, or is it one of the target's keys (os, arch, pointer_bits,
    /// target)?
    pub fn cfg_on(&self, parts: &[String], span: Span) -> Res<bool> {
        let key_only = parts.len() == 1;
        let want = match parts {
            [k] => k.clone(),
            [k, v] => format!("{k}={v}"),
            _ => return err(span, "@cfg(KEY) or @cfg(KEY, VALUE)"),
        };
        // @cfg("release"): an optimized build (--release), for code that trades checks for speed
        if key_only && want == "release" {
            return Ok(self.opts.release);
        }
        let pkg = self.opts.pkg_files.get(&span.file);
        let matches = |c: &str| c == want || key_only && c.split('=').next() == Some(want.as_str());
        // the target's keys, for every package: the host's values (as voltc's runtime names them),
        // unless --cfg gives one for any package, which replaces it (checking another platform's code)
        const TARGET: [&str; 3] = ["os", "arch", "pointer_bits"];
        let given = |k: &str| self.opts.cfg.iter().find_map(|(_, c)| c.strip_prefix(k).and_then(|r| r.strip_prefix('=')).map(String::from));
        // @cfg("hosted"): there's an OS (any target but os=none, bare metal), for std's OS parts
        if key_only && want == "hosted" {
            return Ok(given("os").as_deref() != Some("none"));
        }
        // @cfg("unix"): a POSIX system (Linux, macOS, FreeBSD), for std's code that Windows hasn't
        let os = given("os").unwrap_or_else(|| std::env::consts::OS.to_string());
        if key_only && want == "unix" {
            return Ok(matches!(os.as_str(), "linux" | "macos" | "freebsd"));
        }
        let host = [std::env::consts::OS.to_string(), std::env::consts::ARCH.to_string(), usize::BITS.to_string()];
        // and target: the --target name, on bare metal only (a hosted build has none)
        let on_target = TARGET.iter().zip(host).any(|(k, h)| matches(&format!("{k}={}", given(k).unwrap_or(h)))) || given("target").is_some_and(|t| matches(&format!("target={t}")));
        let is_target = |c: &str| TARGET.contains(&c.split('=').next().unwrap_or("")) || c.split('=').next() == Some("target");
        let set = self.opts.cfg.iter().any(|(p, c)| p.as_ref() == pkg && !is_target(c) && matches(c));
        Ok(set || on_target)
    }

    /// an item's @cfg attributes all hold (an item without one is always in)
    pub fn item_cfg_on(&self, attrs: &[Expr]) -> Res<bool> {
        for a in attrs {
            let ExprKind::Builtin(n, _, Some(args)) = &a.kind else { continue };
            if n != "cfg" {
                continue;
            }
            let mut parts = Vec::new();
            for g in args {
                match g {
                    GenericArg::Expr(Expr { kind: ExprKind::Str(s), .. }) => parts.push(String::from_utf8_lossy(s).into_owned()),
                    _ => return err(a.span, "@cfg takes strings: @cfg(\"os\", \"none\")"),
                }
            }
            if !self.cfg_on(&parts, a.span)? {
                return Ok(false);
            }
        }
        Ok(true)
    }

    /// rejects unknown attributes and wrong argument counts; @intrinsic is allowed only in package files
    pub fn check_attr(&self, a: &Expr, file: u32) -> Res<()> {
        let ExprKind::Builtin(name, _, args) = &a.kind else { return Self::check_user_attr(a) };
        if (name == "intrinsic" || name == "runtime") && self.opts.pkg_files.contains_key(&file) {
            return Ok(());
        }
        let n_args = args.as_ref().map(|a| a.len()).unwrap_or(0);
        if name == "cfg" {
            return if n_args == 1 || n_args == 2 { Ok(()) } else { err(a.span, "@cfg takes 1 or 2 arguments: @cfg(\"os\", \"none\")") };
        }
        if name == "derive" {
            return if n_args >= 1 { Ok(()) } else { err(a.span, "@derive names the traits to attach: @derive(eq, hash)") };
        }
        match ATTRS.iter().find(|(n, _)| n == name) {
            Some((_, want)) if *want == n_args => Ok(()),
            Some((_, want)) => err(a.span, format!("@{name} takes {want} argument(s)")),
            None => {
                let known: Vec<String> = ATTRS.iter().map(|(n, _)| format!("@{n}")).collect();
                err(a.span, format!("unknown attribute @{name} (there are: {})", known.join(", ")))
            }
        }
    }

    /// a comptime value as Volt writes it (what @expand shows)
    pub fn cval_text(&self, v: &CVal) -> String {
        let list = |c: &Self, vs: &[CVal]| vs.iter().map(|x| c.cval_text(x)).collect::<Vec<_>>().join(", ");
        match v {
            CVal::Void => "()".to_string(),
            CVal::Null | CVal::Opt(_, None) => "null".to_string(),
            CVal::Bool(b) => b.to_string(),
            CVal::Int(n, _) => n.to_string(),
            CVal::Float(f, _) => f.to_string(),
            CVal::Str(s) => format!("\"{}\"", String::from_utf8_lossy(s)),
            CVal::Type(t) => self.ty_name(*t),
            CVal::Tuple(vs) => format!("({})", list(self, vs)),
            CVal::Array(vs, _) => format!("{{ {} }}", list(self, vs)),
            CVal::Struct(t, fs) => {
                let body = fs.iter().map(|(n, x)| format!("{n}: {}", self.cval_text(x))).collect::<Vec<_>>().join(", ");
                if *t == VOID { format!("{{ {body} }}") } else { format!("{} {{ {body} }}", self.ty_name(*t)) }
            }
            CVal::Variant(_, n, p) => match p {
                Some(x) => format!(".{n}({})", self.cval_text(x)),
                None => format!(".{n}"),
            },
            CVal::Opt(_, Some(x)) => self.cval_text(x),
        }
    }

    /// a fn instance as its signature (its name has its generic args): twice<i32>(v: i32) -> i32
    pub fn inst_label(&self, i: usize) -> String {
        let f = &self.fns[i];
        let ps: Vec<String> = f.params.iter().map(|p| format!("{}: {}", p.name, self.ty_name(p.ty))).collect();
        format!("{}({}) -> {}", f.name, ps.join(", "), self.ty_name(f.ret))
    }

    /// a value spliced into a quote, as source text: a str's text (a name, or code), a type by its
    /// name, a number, a bool
    fn splice_text(&mut self, v: CVal, span: Span) -> CRes<String> {
        Ok(match v {
            CVal::Str(s) => String::from_utf8_lossy(&s).into_owned(),
            CVal::Type(t) => self.ty_name(t),
            CVal::Int(n, _) => n.to_string(),
            CVal::Bool(b) => b.to_string(),
            CVal::Struct(t, _) => return cerr(span, format!("can't splice a {} into code (it takes text, a type, a number or a bool)", self.ty_name(t))),
            _ => return cerr(span, "can't splice this value into code (it takes text, a type, a number or a bool)"),
        })
    }

    /// a library's attribute: a struct (or comptime fn) named and called, or a comptime value's name;
    /// it's evaluated when @typeinfo reads it
    pub fn check_user_attr(a: &Expr) -> Res<()> {
        match &a.kind {
            ExprKind::Path(_) => Ok(()),
            ExprKind::Call(f, _) if matches!(f.kind, ExprKind::Path(_)) => Ok(()),
            _ => err(a.span, "an attribute is a builtin (@inline) or a library's value (json::rename(\"id\"))"),
        }
    }

    /// a library's attribute's value: a struct's name called like a function is that struct, its
    /// fields filled in order (the rest take their defaults); anything else is a comptime value
    pub fn user_attr(&mut self, e: &Expr, env: &Rc<Env>) -> Res<CVal> {
        if let ExprKind::Call(callee, args) = &e.kind {
            if let ExprKind::Path(p) = &callee.kind {
                let as_ty = Type { kind: TypeKind::Path(p.clone()), span: callee.span };
                if let Ok(t) = self.resolve_type(&as_ty, env) {
                    if let Ty::Struct(sid) = self.t.get(t).clone() {
                        let fields = self.struct_fields(sid, e.span)?;
                        if args.len() > fields.len() {
                            return err(e.span, format!("{} has {} field(s), given {} values", self.ty_name(t), fields.len(), args.len()));
                        }
                        let entries = args.iter().zip(fields.iter()).map(|(a, f)| (Some(f.name.clone()), a.clone())).collect();
                        return self.ct_eval_in(env.clone(), &Expr { kind: ExprKind::Literal(entries), span: e.span }, Some(t));
                    }
                }
            }
        }
        self.ct_eval_in(env.clone(), e, None)
    }

    /// the library attributes among attrs (the builtins mean something to the compiler, and aren't
    /// listed), as a tuple
    fn user_attrs(&mut self, attrs: &[Expr], env: &Rc<Env>) -> Res<CVal> {
        let mut out = Vec::new();
        for a in attrs {
            if !matches!(a.kind, ExprKind::Builtin(..)) {
                out.push(self.user_attr(a, env)?);
            }
        }
        Ok(CVal::Tuple(out))
    }

    /// an attribute's first argument as text (an int or a string)
    fn attr_arg(a: &Expr) -> Option<String> {
        let ExprKind::Builtin(_, _, Some(args)) = &a.kind else { return None };
        match args.first()? {
            GenericArg::Expr(Expr { kind: ExprKind::Int(v), .. }) => Some(v.to_string()),
            GenericArg::Expr(Expr { kind: ExprKind::Str(s), .. }) => Some(String::from_utf8_lossy(s).into_owned()),
            _ => None,
        }
    }

    /// C spelling of a function's attributes
    pub fn c_attrs(&self, attrs: &[Expr]) -> String {
        let mut out = String::new();
        for a in attrs {
            let ExprKind::Builtin(name, _, _) = &a.kind else { continue };
            let arg = Self::attr_arg(a).unwrap_or_default();
            out.push_str(&match name.as_str() {
                "inline" => "__attribute__((always_inline)) inline ".to_string(),
                "noinline" => "__attribute__((noinline)) ".to_string(),
                "opt" => format!("__attribute__((optimize(\"O{arg}\"))) "),
                "section" => format!("__attribute__((section({}))) ", super::cty::c_str_lit(arg.as_bytes())),
                "align" => format!("__attribute__((aligned({arg}))) "),
                "deprecated" => "__attribute__((deprecated)) ".to_string(),
                _ => String::new(),
            });
        }
        out
    }

    /// print a deprecation warning the first time a deprecated function is used
    pub fn warn_deprecated(&mut self, idx: usize, span: Span) {
        let decl = self.fns[idx].decl;
        let msg = self.decls[decl].item.attrs.iter().find_map(|a| match &a.kind {
            ExprKind::Builtin(n, _, _) if n == "deprecated" => Some(Self::attr_arg(a).unwrap_or_default()),
            _ => None,
        });
        if let Some(m) = msg {
            if self.warned.insert(decl) {
                let d = Diag { severity: crate::diag::Severity::Warning, ..Diag::new(span, format!("'{}' is deprecated: {m}", self.fns[idx].name)) };
                self.warnings.push(d.label(self.decls[decl].item.span, "declared here"));
            }
        }
    }
}
