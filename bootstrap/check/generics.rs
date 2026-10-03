// Templates: generic params, inference, overload resolution for every call form
// (f(), Type::f(), x.f()), trait bounds, and traits used as types (tagged unions).
use super::*;

/// the kind of a generic param: a type, a type pack (T...), or a value of this type (<N: i32>)
#[derive(Clone, Copy, PartialEq, Debug)]
pub enum PKind {
    Type,
    Pack,
    Const(TyId),
}

/// how a method call passes its receiver to `this`: as it is, by taking its address (Ref), or
/// through the reference it is (Deref)
#[derive(Clone, Copy, PartialEq, Debug)]
pub enum Adj {
    None,
    Ref,
    Deref,
}

/// a fn's receiver with its type pattern: none (a plain fn), `static this` (called as Type::f()), or
/// a value (called as x.f())
pub enum Recv {
    None,
    Static(Type),
    Val(Type),
}

/// a trait used as a type: a tagged union of the types attached to it (members, in tag order)
pub struct UnionInfo {
    pub trait_decl: DeclId,
    pub name: String,
    pub c_name: String,
    pub members: Vec<TyId>,
}

/// what Type::name refers to: a member of a known type, or a variant of a generic enum written
/// without its args (the instance is inferred: infer_enum)
pub enum Member {
    Of(TyId, String),
    GenericEnum(DeclId, String),
}

impl Checker {
    /// generic params of a fn: its attach block's, its own, then its comptime params
    /// (a comptime param is a value parameter of the instance, like <N: i32>)
    pub fn fn_generics(&self, decl: DeclId) -> Vec<GenericParam> {
        let d = &self.decls[decl];
        let mut out = Vec::new();
        if let Some(p) = d.parent {
            if matches!(self.decls[p].item.kind, ItemKind::AttachBlock { .. }) {
                out.extend(self.decls[p].item.generics.iter().cloned());
            }
        }
        out.extend(d.item.generics.iter().cloned());
        if let ItemKind::Fn(f) = &d.item.kind {
            for p in f.params.iter().filter(|p| p.comptime) {
                out.push(GenericParam {
                    name: p.name.clone(),
                    bounds: p.ty.clone().into_iter().collect(),
                    pack: false,
                    default: p.default.clone().map(GenericArg::Expr),
                    span: p.span,
                });
            }
        }
        out
    }

    fn is_type_bound(t: &Type) -> bool {
        matches!(&t.kind, TypeKind::Path(p) if p.is_single() && p.segs[0].name == "type")
    }

    /// the trait a bound names, with its generic args
    pub fn bound_trait(&self, t: &Type, ns: NsId) -> Option<(DeclId, Vec<GenericArg>)> {
        let TypeKind::Path(p) = &t.kind else { return None };
        let found = if p.segs.len() == 1 { self.lookup(ns, &p.segs[0].name) } else { self.lookup_path_ns(ns, p) };
        match found {
            Some(Found::Decls(ds)) => ds
                .into_iter()
                .find(|d| matches!(self.decls[*d].item.kind, ItemKind::Trait { .. }))
                .map(|d| (d, p.segs.last().unwrap().args.clone().unwrap_or_default())),
            _ => None,
        }
    }

    /// a pack, a type (every bound is `type` or a trait), or else a value of its one bound's type
    pub fn param_kind(&mut self, gp: &GenericParam, env: &Rc<Env>) -> Res<PKind> {
        if gp.pack {
            return Ok(PKind::Pack);
        }
        if gp.bounds.iter().all(|b| Self::is_type_bound(b) || self.bound_trait(b, env.ns).is_some()) {
            return Ok(PKind::Type);
        }
        if gp.bounds.len() != 1 {
            return err(gp.span, "a value parameter has exactly one type: <N: i32>");
        }
        Ok(PKind::Const(self.resolve_type(&gp.bounds[0], env)?))
    }

    /// a generic arg read as a type (a bare name parses as an expression)
    pub fn garg_type_env(&mut self, g: &GenericArg, env: &Rc<Env>) -> Res<TyId> {
        match g {
            GenericArg::Type(t) => self.resolve_type(t, env),
            GenericArg::Expr(Expr { kind: ExprKind::Path(p), .. }) => {
                let t = Type { kind: TypeKind::Path(p.clone()), span: p.span };
                self.resolve_type(&t, env)
            }
            GenericArg::Expr(e) => err(e.span, "expected a type"),
        }
    }

    /// a generic arg's value for a param of this kind; value args are evaluated at compile time in env
    pub fn garg_gval(&mut self, g: &GenericArg, kind: PKind, env: &Rc<Env>) -> Res<GVal> {
        match kind {
            PKind::Type => Ok(GVal::Ty(self.garg_type_env(g, env)?)),
            PKind::Const(t) => {
                let e = Self::garg_value(g)?;
                if t == STR || t == CSTR {
                    return match self.ct_eval_in(env.clone(), &e, Some(t))? {
                        comptime::CVal::Str(s) => Ok(GVal::Str(s)),
                        _ => err(e.span, "expected a string known at compile time"),
                    };
                }
                if t == BOOL {
                    return match self.ct_eval_in(env.clone(), &e, Some(t))? {
                        comptime::CVal::Bool(b) => Ok(GVal::Int(b as i128)),
                        _ => err(e.span, "expected a bool known at compile time"),
                    };
                }
                Ok(GVal::Int(self.const_int(&e, env)?))
            }
            PKind::Pack => match g {
                GenericArg::Type(t) => err(t.span, "pass pack members as ordinary arguments"),
                GenericArg::Expr(e) => err(e.span, "pass pack members as ordinary arguments"),
            },
        }
    }

    /// an env with the params bound so far (unbound ones are left out)
    pub fn partial_env(&self, ns: NsId, gps: &[GenericParam], binds: &[Option<GVal>]) -> Rc<Env> {
        Rc::new(Env { ns, generics: gps.iter().zip(binds).filter_map(|(g, b)| b.clone().map(|b| (g.name.clone(), b))).collect() })
    }

    /// the type pat denotes with these bindings, or None if it names an unbound param or doesn't resolve
    fn resolve_partial(&mut self, pat: &Type, gps: &[GenericParam], binds: &[Option<GVal>], ns: NsId) -> Option<TyId> {
        let env = self.partial_env(ns, gps, binds);
        self.resolve_type(pat, &env).ok()
    }

    /// generic args for a generic type: given ones, then defaults
    pub fn gargs_for(&mut self, decl: DeclId, given: &[GenericArg], caller: &Rc<Env>, span: Span) -> Res<Vec<GVal>> {
        let gps = self.decls[decl].item.generics.clone();
        let ns = self.decls[decl].ns;
        if given.len() > gps.len() {
            return err(span, format!("too many generic arguments (expected {})", gps.len()));
        }
        let mut binds: Vec<Option<GVal>> = vec![None; gps.len()];
        for (i, gp) in gps.iter().enumerate() {
            let env = self.partial_env(ns, &gps, &binds);
            let kind = self.param_kind(gp, &env)?;
            binds[i] = Some(match given.get(i) {
                Some(g) => self.garg_gval(g, kind, caller)?,
                None => match &gp.default {
                    Some(d) => self.garg_gval(d, kind, &env)?,
                    None => return err(span, format!("missing generic argument '{}'", gp.name)),
                },
            });
        }
        let out: Vec<GVal> = binds.into_iter().map(Option::unwrap).collect();
        if let Err(m) = self.check_bounds(&gps, &out, ns)? {
            return err(span, m);
        }
        Ok(out)
    }

    // ---------- inference ----------

    /// the struct/enum decl a type pattern path names (its primary, unspecialized decl)
    fn pattern_family(&self, p: &Path, ns: NsId) -> Option<DeclId> {
        let found = if p.segs.len() == 1 { self.lookup(ns, &p.segs[0].name) } else { self.lookup_path_ns(ns, p) };
        match found {
            Some(Found::Decls(ds)) => ds.into_iter().find(|d| match &self.decls[*d].item.kind {
                ItemKind::Struct(s) => s.spec.is_none(),
                ItemKind::Enum(_) => true,
                _ => false,
            }),
            _ => None,
        }
    }

    /// bind generic params (by name) that appear in `pat` from the actual type
    pub fn infer(&self, pat: &Type, actual: TyId, gps: &[GenericParam], binds: &mut [Option<GVal>], ns: NsId) {
        let idx = |name: &str| gps.iter().position(|g| g.name == name);
        let actual_ty = self.t.get(actual).clone();
        match (&pat.kind, actual_ty) {
            (TypeKind::Path(p), _) if p.is_single() && idx(&p.segs[0].name).is_some() => {
                let i = idx(&p.segs[0].name).unwrap();
                if binds[i].is_none() {
                    binds[i] = Some(GVal::Ty(actual));
                }
            }
            // a generic struct/enum pattern (vec<T>) against an instance of that family: match the args
            (TypeKind::Path(p), Ty::Struct(_) | Ty::Enum(_)) if p.segs.last().unwrap().args.is_some() => {
                let (family, args) = match self.t.get(actual) {
                    Ty::Struct(s) => (self.structs[*s as usize].family, self.structs[*s as usize].args.clone()),
                    Ty::Enum(e) => (self.enums[*e as usize].family, self.enums[*e as usize].args.clone()),
                    _ => unreachable!(),
                };
                if self.pattern_family(p, ns) != Some(family) {
                    return;
                }
                for (pa, a) in p.segs.last().unwrap().args.as_ref().unwrap().iter().zip(args) {
                    let name_of = |g: &GenericArg| match g {
                        GenericArg::Type(Type { kind: TypeKind::Path(p), .. }) | GenericArg::Expr(Expr { kind: ExprKind::Path(p), .. }) if p.is_single() => {
                            Some(p.segs[0].name.clone())
                        }
                        _ => None,
                    };
                    match (pa, &a) {
                        (_, GVal::Int(v)) => {
                            if let Some(i) = name_of(pa).and_then(|n| idx(&n)) {
                                if binds[i].is_none() {
                                    binds[i] = Some(GVal::Int(*v));
                                }
                            }
                        }
                        (GenericArg::Type(t), GVal::Ty(at)) => self.infer(t, *at, gps, binds, ns),
                        (GenericArg::Expr(Expr { kind: ExprKind::Path(p), span }), GVal::Ty(at)) => {
                            let t = Type { kind: TypeKind::Path(p.clone()), span: *span };
                            self.infer(&t, *at, gps, binds, ns)
                        }
                        _ => {}
                    }
                }
            }
            (TypeKind::Ref(i), Ty::Ref(a)) => self.infer(i, a, gps, binds, ns),
            // a T& converts to a T*, so a pointer pattern sees through references too
            (TypeKind::Ptr(i), Ty::Ptr(a) | Ty::Ref(a)) => self.infer(i, a, gps, binds, ns),
            (TypeKind::Optional(i), Ty::Opt(a)) => self.infer(i, a, gps, binds, ns),
            (TypeKind::Optional(i), _) => self.infer(i, actual, gps, binds, ns),
            (TypeKind::Array(i, n), Ty::Array(a, len)) => {
                self.infer(i, a, gps, binds, ns);
                if let Some(ExprKind::Path(np)) = n.as_ref().map(|n| &n.kind) {
                    if let Some(j) = np.is_single().then(|| idx(&np.segs[0].name)).flatten() {
                        if binds[j].is_none() {
                            binds[j] = Some(GVal::Int(len as i128));
                        }
                    }
                }
            }
            (TypeKind::Slice(i), Ty::Slice(a) | Ty::Array(a, _)) => self.infer(i, a, gps, binds, ns),
            (TypeKind::Tuple(ps), Ty::Tuple(ts, _)) if ps.len() == ts.len() => {
                for ((_, p), t) in ps.iter().zip(ts) {
                    self.infer(p, t, gps, binds, ns);
                }
            }
            (TypeKind::ErrorUnion(e, i), Ty::ErrUnion(ae, at)) => {
                if let Some(e) = e {
                    self.infer(e, ae, gps, binds, ns);
                }
                self.infer(i, at, gps, binds, ns);
            }
            (TypeKind::Fn { params, ret, .. }, Ty::FnPtr(ps, r, _) | Ty::FnVal(ps, r)) if params.len() == ps.len() => {
                for (p, a) in params.iter().zip(ps) {
                    self.infer(p, a, gps, binds, ns);
                }
                self.infer(ret, r, gps, binds, ns);
            }
            _ => {}
        }
    }

    // ---------- candidates ----------

    /// a fn's receiver: `this`'s declared type, else its attach block's target (T& for a non-static this)
    pub fn recv_of(&self, decl: DeclId) -> Recv {
        let ItemKind::Fn(f) = &self.decls[decl].item.kind else { return Recv::None };
        let Some(p) = f.params.first().filter(|p| p.name == "this") else { return Recv::None };
        let target = self.decls[decl].parent.and_then(|b| match &self.decls[b].item.kind {
            ItemKind::AttachBlock { target, .. } => Some(target.clone()),
            _ => None,
        });
        let pat = match (&p.ty, target) {
            (Some(t), _) => t.clone(),
            (None, Some(t)) if p.is_static => t,
            (None, Some(t)) => Type { span: t.span, kind: TypeKind::Ref(Box::new(t)) },
            (None, None) => return Recv::None,
        };
        if p.is_static { Recv::Static(pat) } else { Recv::Val(pat) }
    }

    /// Does a receiver of type r fit the pattern (binding its generics)? As it is, else by reference
    /// (the method takes a T&, r is a T), else through r's reference (r is a T&, the method takes a T).
    fn match_recv(&mut self, pat: &Type, r: TyId, gps: &[GenericParam], binds: &mut [Option<GVal>], ns: NsId) -> Option<Adj> {
        // `this: T*` takes its receiver like `this: T&` (a T& converts to the T*)
        let as_ref;
        let pat = match &pat.kind {
            TypeKind::Ptr(i) => {
                as_ref = Type { kind: TypeKind::Ref(i.clone()), span: pat.span };
                &as_ref
            }
            _ => pat,
        };
        let mut b = binds.to_vec();
        self.infer(pat, r, gps, &mut b, ns);
        if self.resolve_partial(pat, gps, &b, ns) == Some(r) {
            binds.clone_from_slice(&b);
            return Some(Adj::None);
        }
        if let TypeKind::Ref(inner) = &pat.kind {
            let mut b = binds.to_vec();
            self.infer(inner, r, gps, &mut b, ns);
            if self.resolve_partial(inner, gps, &b, ns) == Some(r) {
                binds.clone_from_slice(&b);
                return Some(Adj::Ref);
            }
        }
        if let Ty::Ref(d) = self.t.get(r).clone() {
            let mut b = binds.to_vec();
            self.infer(pat, d, gps, &mut b, ns);
            if self.resolve_partial(pat, gps, &b, ns) == Some(d) {
                binds.clone_from_slice(&b);
                return Some(Adj::Deref);
            }
        }
        None
    }

    /// Bind a candidate's generics for a call. Err(reason) when it doesn't fit.
    #[allow(clippy::too_many_arguments)]
    pub fn bind_cand(
        &mut self,
        decl: DeclId,
        recv: Option<&Val>,
        static_ty: Option<TyId>,
        explicit: &[GenericArg],
        args: &[Option<Val>],
    ) -> Res<Result<(Vec<GVal>, Adj), String>> {
        let item = self.decls[decl].item.clone();
        let ItemKind::Fn(f) = &item.kind else { unreachable!() };
        let ns = self.decls[decl].ns;
        let gps = self.fn_generics(decl);
        let mut binds: Vec<Option<GVal>> = vec![None; gps.len()];
        let mut adj = Adj::None;
        match (recv, static_ty, self.recv_of(decl)) {
            (Some(r), None, Recv::Val(pat)) => match self.match_recv(&pat, r.ty, &gps, &mut binds, ns) {
                Some(a) => adj = a,
                None => return Ok(Err(format!("'{}' doesn't take a {} as this", f.name, self.ty_name(r.ty)))),
            },
            (None, Some(t), Recv::Static(pat)) => {
                self.infer(&pat, t, &gps, &mut binds, ns);
                if self.resolve_partial(&pat, &gps, &binds, ns) != Some(t) {
                    return Ok(Err(format!("'{}' isn't attached to {}", f.name, self.ty_name(t))));
                }
            }
            (None, None, Recv::None | Recv::Static(_)) => {}
            (Some(_), _, _) => return Ok(Err(format!("'{}' isn't a method", f.name))),
            (None, Some(t), _) => return Ok(Err(format!("'{}' isn't a static function of {} (static this)", f.name, self.ty_name(t)))),
            (None, None, Recv::Val(_)) => return Ok(Err(format!("'{}' is a method; call it as x.{}()", f.name, f.name))),
        }
        // explicit generic args fill the params the receiver left unbound, in order
        let caller = self.cx.env.clone();
        let mut ei = 0;
        for i in 0..gps.len() {
            if binds[i].is_none() && ei < explicit.len() {
                let env = self.partial_env(ns, &gps, &binds);
                let kind = self.param_kind(&gps[i], &env)?;
                binds[i] = Some(self.garg_gval(&explicit[ei], kind, &caller)?);
                ei += 1;
            }
        }
        if ei < explicit.len() {
            return Ok(Err(format!("too many generic arguments for '{}'", f.name)));
        }
        // check the argument count, then infer from the argument types (a comptime param takes the
        // argument's value, which has to be a literal)
        let vparams: Vec<&Param> = f.params.iter().filter(|p| p.name != "this").collect();
        let has_pack = vparams.last().is_some_and(|p| matches!(p.ty.as_ref().map(|t| &t.kind), Some(TypeKind::Pack(_))));
        let fixed = vparams.len() - has_pack as usize;
        let required = vparams[..fixed].iter().filter(|p| p.default.is_none()).count();
        if args.len() < required || (args.len() > fixed && !has_pack && !f.c_varargs) {
            return Ok(Err(format!("'{}' takes {} arguments, found {}", f.name, fixed, args.len())));
        }
        for (p, a) in vparams[..fixed].iter().zip(args) {
            if p.comptime {
                let j = gps.iter().position(|g| g.name == p.name).unwrap();
                binds[j] = match a.as_ref().and_then(|v| v.lit.clone()) {
                    Some(Lit::Int(n)) => Some(GVal::Int(n)),
                    Some(Lit::Str(s)) => Some(GVal::Str(s)),
                    _ if a.as_ref().is_some_and(|v| v.ty == BOOL && (v.c == "true" || v.c == "false")) => Some(GVal::Int((a.as_ref().unwrap().c == "true") as i128)),
                    _ => return Ok(Err(format!("the argument for comptime parameter '{}' must be known at compile time", p.name))),
                };
                continue;
            }
            if let (Some(pt), Some(v)) = (&p.ty, a) {
                self.infer(pt, v.ty, &gps, &mut binds, ns);
            }
        }
        // a pack binds to the types of all the remaining arguments
        if has_pack {
            let Some(TypeKind::Pack(inner)) = vparams[fixed].ty.as_ref().map(|t| &t.kind) else { unreachable!() };
            let rest = args.get(fixed..).unwrap_or(&[]);
            let tys: Option<Vec<TyId>> = rest.iter().map(|a| a.as_ref().map(|v| v.ty)).collect();
            let Some(tys) = tys else { return Ok(Err("pack arguments need types that are known up front".into())) };
            if let TypeKind::Path(p) = &inner.kind {
                if let Some(j) = p.is_single().then(|| gps.iter().position(|g| g.name == p.segs[0].name)).flatten() {
                    binds[j] = Some(GVal::Pack(tys));
                }
            }
        }
        // whatever is still unbound takes its default; an unbound pack is empty
        for i in 0..gps.len() {
            if binds[i].is_some() {
                continue;
            }
            let env = self.partial_env(ns, &gps, &binds);
            if let Some(d) = gps[i].default.clone() {
                let kind = self.param_kind(&gps[i], &env)?;
                binds[i] = Some(self.garg_gval(&d, kind, &env)?);
            } else if gps[i].pack {
                binds[i] = Some(GVal::Pack(Vec::new()));
            } else {
                return Ok(Err(format!("can't infer '{}' for '{}'; pass it: {}<...>(...)", gps[i].name, f.name, f.name)));
            }
        }
        let binds: Vec<GVal> = binds.into_iter().map(Option::unwrap).collect();
        if let Err(m) = self.check_bounds(&gps, &binds, ns)? {
            return Ok(Err(m));
        }
        Ok(Ok((binds, adj)))
    }

    /// kinds match and trait bounds hold
    pub fn check_bounds(&mut self, gps: &[GenericParam], binds: &[GVal], ns: NsId) -> Res<Result<(), String>> {
        let env = Rc::new(Env { ns, generics: gps.iter().zip(binds).map(|(g, b)| (g.name.clone(), b.clone())).collect() });
        for (gp, b) in gps.iter().zip(binds) {
            match (self.param_kind(gp, &env)?, b) {
                (PKind::Type, GVal::Ty(t)) => {
                    for bound in &gp.bounds {
                        if let Some((tr, targs)) = self.bound_trait(bound, ns) {
                            if !self.satisfies(*t, tr, &targs, &env)? {
                                let tname = self.decl_name(tr);
                                return Ok(Err(format!("{} = {} doesn't attach {tname}", gp.name, self.ty_name(*t))));
                            }
                        }
                    }
                }
                (PKind::Const(t), GVal::Str(_)) if t == STR || t == CSTR => {}
                (PKind::Const(t), GVal::Int(v)) => {
                    if let Some(k) = self.t.int_of(t) {
                        if !k.fits(*v) {
                            return Ok(Err(format!("{} = {v} doesn't fit in {}", gp.name, k.name())));
                        }
                    }
                }
                (PKind::Pack, GVal::Pack(_)) => {}
                (PKind::Type, _) => return Ok(Err(format!("'{}' needs a type", gp.name))),
                (PKind::Const(_), _) => return Ok(Err(format!("'{}' needs a value", gp.name))),
                (PKind::Pack, _) => return Ok(Err(format!("'{}' is a pack", gp.name))),
            }
        }
        Ok(Ok(()))
    }

    pub fn decl_name(&self, d: DeclId) -> String {
        match &self.decls[d].item.kind {
            ItemKind::Fn(f) => f.name.clone(),
            ItemKind::Struct(s) => s.name.clone(),
            ItemKind::Enum(e) => e.name.clone(),
            ItemKind::Trait { name, .. } => name.clone(),
            ItemKind::Global(l) => match &l.pat.kind {
                PatKind::Bind(n) => n.clone(),
                _ => "?".into(),
            },
            _ => "?".into(),
        }
    }

    /// does `ty` attach the trait (with these args)?
    /// A trait union attaches its own trait; any other type needs an attach block for the trait whose
    /// target matches it, with the same trait args.
    pub fn satisfies(&mut self, ty: TyId, trait_decl: DeclId, targs: &[GenericArg], env: &Rc<Env>) -> Res<bool> {
        if let Ty::TraitUnion(u) = self.t.get(ty) {
            if self.unions[*u as usize].trait_decl == trait_decl {
                return Ok(true);
            }
        }
        let want_args: Vec<TyId> = targs.iter().map(|g| self.garg_type_env(g, env)).collect::<Res<_>>()?;
        for b in self.attach_blocks.clone() {
            let item = self.decls[b].item.clone();
            let ns = self.decls[b].ns;
            let ItemKind::AttachBlock { trait_, target, .. } = &item.kind else { continue };
            let Some((tr, block_targs)) = self.bound_trait(trait_, ns) else { continue };
            if tr != trait_decl {
                continue;
            }
            let gps = item.generics.clone();
            let mut binds = vec![None; gps.len()];
            self.infer(target, ty, &gps, &mut binds, ns);
            if self.resolve_partial(target, &gps, &binds, ns) != Some(ty) {
                continue;
            }
            let penv = self.partial_env(ns, &gps, &binds);
            let got: Res<Vec<TyId>> = block_targs.iter().map(|g| self.garg_type_env(g, &penv)).collect();
            if got.ok().as_deref() == Some(&want_args[..]) {
                return Ok(true);
            }
        }
        Ok(false)
    }

    // ---------- calls ----------

    /// arguments that can't be checked without an expected type (aggregate literals, .VARIANT, null,
    /// closures with untyped params); calls check them against the chosen candidate's params
    pub fn needs_context(e: &Expr) -> bool {
        match &e.kind {
            ExprKind::Literal(_) | ExprKind::Repeat(..) | ExprKind::DotVariant(_) | ExprKind::Null => true,
            ExprKind::Closure { params, .. } => params.iter().any(|p| p.ty.is_none()),
            ExprKind::Call(c, _) => matches!(c.kind, ExprKind::DotVariant(_)),
            _ => false,
        }
    }

    /// can decl `d` take `n` arguments (receiver not counted)?
    fn arity_fits(&self, d: DeclId, n: usize) -> bool {
        let ItemKind::Fn(f) = &self.decls[d].item.kind else { return false };
        let ps: Vec<&Param> = f.params.iter().filter(|p| p.name != "this").collect();
        let pack = ps.last().is_some_and(|p| matches!(p.ty.as_ref().map(|t| &t.kind), Some(TypeKind::Pack(_))));
        let required = ps.iter().filter(|p| p.default.is_none()).count() - pack as usize;
        n >= required && (n <= ps.len() || pack || f.c_varargs)
    }

    /// How many of a fn's receiver and parameters are a bare generic parameter (T, T&, T*, T...): a blanket
    /// version (`<T> eq(this: T&, other: T&)`) has more than one written for a type (`string<A>&`)
    fn blanket_positions(&self, decl: DeclId) -> usize {
        let ItemKind::Fn(f) = &self.decls[decl].item.kind else { return 0 };
        let gps = self.fn_generics(decl);
        let bare = |t: &Type| {
            let inner = match &t.kind {
                TypeKind::Ref(i) | TypeKind::Ptr(i) | TypeKind::Pack(i) => &**i,
                _ => t,
            };
            matches!(&inner.kind, TypeKind::Path(p) if p.is_single() && gps.iter().any(|g| g.name == p.segs[0].name))
        };
        let mut n = match self.recv_of(decl) {
            Recv::Val(pat) | Recv::Static(pat) => bare(&pat) as usize,
            Recv::None => 0,
        };
        for p in f.params.iter().filter(|p| p.name != "this") {
            n += p.ty.as_ref().is_some_and(|t| bare(t)) as usize;
        }
        n
    }

    /// Pick one of the overloads `cands` for a call and emit it. Every candidate that fits is scored:
    /// per argument 3 for its exact type, 1 for a coercion; 2 when it returns the wanted type, 1 when
    /// it isn't generic. The best score has to be unique, or the call is ambiguous; between equal
    /// scores, the one with fewer blanket positions (more specific) wins.
    pub fn resolve_call(
        &mut self,
        name: &str,
        cands: &[DeclId],
        recv: Option<Val>,
        static_ty: Option<TyId>,
        explicit: &[GenericArg],
        args: &[Expr],
        want: Option<TyId>,
        span: Span,
    ) -> Res<Val> {
        if let [d] = cands {
            if let Some(intr) = self.intrinsic_of(*d).filter(|i| matches!(i.as_str(), "println" | "print" | "eprintln" | "eprint" | "write" | "format")) {
                // format makes a value of the type its declaration returns (std says std::string)
                let ret = match &self.decls[*d].item.kind {
                    ItemKind::Fn(FnDecl { ret: Some(r), .. }) if intr == "format" => {
                        let (r, env) = (r.clone(), Rc::new(Env { ns: self.decls[*d].ns, generics: Vec::new() }));
                        self.resolve_type(&r, &env)?
                    }
                    _ => VOID,
                };
                return self.intrinsic(&intr, args, ret, span);
            }
        }
        // one candidate takes this many arguments: its parameter types can guide them (so a
        // return-type overload in an argument gets its context), if they don't hang on the arguments
        let mut wants: Vec<Option<TyId>> = vec![None; args.len()];
        let fits: Vec<DeclId> = cands.iter().copied().filter(|d| self.arity_fits(*d, args.len())).collect();
        if let [d] = fits[..] {
            let inst = if self.fn_generics(d).is_empty() {
                Some(self.fn_inst(d, Vec::new(), span)?)
            } else {
                let unknown = vec![None; args.len()];
                match self.bind_cand(d, recv.as_ref(), static_ty, explicit, &unknown) {
                    Ok(Ok((binds, _))) => self.fn_inst(d, binds, span).ok(),
                    _ => None,
                }
            };
            if let Some(i) = inst {
                let off = recv.is_some() as usize;
                for (k, w) in wants.iter_mut().enumerate() {
                    *w = self.fns[i].params.get(k + off).map(|p| p.ty);
                }
            }
        }
        // check the arguments once, before choosing; those needing context wait for emit_call
        let mut pre = Vec::new();
        for (a, w) in args.iter().zip(&wants) {
            pre.push(if Self::needs_context(a) { None } else { Some(self.expr(a, *w)?) });
        }
        let mut viable: Vec<(usize, Adj, i32, usize)> = Vec::new();
        // why each candidate doesn't fit; a lone one is the error itself
        let mut reasons: Vec<Diag> = Vec::new();
        for &d in cands {
            let (binds, adj) = match self.bind_cand(d, recv.as_ref(), static_ty, explicit, &pre)? {
                Ok(x) => x,
                Err(r) => {
                    reasons.push(Diag::new(span, r));
                    continue;
                }
            };
            let inst = match self.fn_inst(d, binds, span) {
                Ok(i) => i,
                Err(e) => {
                    reasons.push(e);
                    continue;
                }
            };
            let f = self.fns[inst].clone();
            let offset = recv.is_some() as usize;
            let fixed = f.params.len() - offset - f.pack as usize;
            let mut score = 0;
            let mut ok = true;
            for (i, a) in pre.iter().enumerate().take(fixed) {
                let (Some(v), Some(p)) = (a, f.params.get(i + offset)) else { continue };
                if v.ty == p.ty {
                    score += 3;
                } else if self.coercible(v, p.ty) {
                    score += 1;
                } else {
                    ok = false;
                    let msg = format!("argument {} is a {}, but '{}' wants a {}", i + 1, self.ty_name(v.ty), name, self.ty_name(p.ty));
                    let mut r = Diag::new(args[i].span, msg);
                    if let ItemKind::Fn(fd) = &self.decls[d].item.kind {
                        if let Some(ap) = fd.params.iter().find(|ap| ap.name == p.name) {
                            r = r.label(ap.span, "parameter declared here");
                        }
                    }
                    reasons.push(r);
                    break;
                }
            }
            if !ok {
                continue;
            }
            if want == Some(f.ret) {
                score += 2;
            }
            if self.fn_generics(d).is_empty() {
                score += 1;
            }
            viable.push((inst, adj, score, self.blanket_positions(d)));
        }
        viable.sort_by_key(|v| (-v.2, v.3));
        // versions attached to other types are no news once some version takes this receiver
        if let Some(r) = &recv {
            let other = format!("'{name}' doesn't take a {} as this", self.ty_name(r.ty));
            if reasons.iter().any(|d| d.msg != other) {
                reasons.retain(|d| d.msg != other);
            } else {
                reasons.truncate(1);
            }
        }
        let (inst, adj) = match viable.as_slice() {
            [] if reasons.len() == 1 => return Err(reasons.remove(0)),
            [] => {
                let why: Vec<String> = reasons.iter().map(|r| r.msg.clone()).collect();
                return err(span, format!("no version of '{name}' fits: {}", why.join("; ")));
            }
            [(i, a, _, _)] => (*i, *a),
            [(i, a, s1, b1), (_, _, s2, b2), ..] if s1 > s2 || b1 < b2 => (*i, *a),
            _ => return err(span, format!("call to '{name}' is ambiguous (several versions fit); add types to the arguments or the result")),
        };
        self.emit_call(inst, adj, recv, &pre, args, span)
    }

    /// Emit a call of fn instance `inst`: adjust the receiver, convert the arguments (a pack's become
    /// one tuple, C varargs are promoted), and fill in defaults, checked in the callee's env. A
    /// temporary made to pass a receiver by reference is deleted after the call.
    fn emit_call(&mut self, inst: usize, adj: Adj, recv: Option<Val>, pre: &[Option<Val>], args: &[Expr], span: Span) -> Res<Val> {
        let f = self.fns[inst].clone();
        self.visible(f.decl, span)?;
        let site = self.open_site(Body::Fn(inst), f.ret);
        let mut vals = Vec::new();
        let mut prefix = String::new();
        let mut post = String::new();
        if let Some(r) = recv {
            // what the receiver lends this: the place itself (Ref), or the reference it is (None)
            match adj {
                Adj::Ref => {
                    // a temporary's slot is fresh, but what it points at may not be
                    self.note_mut(&r);
                    let (ro, via, root) = Self::addr_prov(&r);
                    self.note_arg(Body::Fn(inst), 0, ro, via, root.as_deref(), span, site);
                }
                Adj::None => self.note_arg(Body::Fn(inst), 0, r.ro, r.via, r.root.as_deref(), span, site),
                _ => {}
            }
            vals.push(match adj {
                Adj::None => {
                    let pt = f.params[0].ty;
                    self.take(r, span).map(|v| Val { ty: pt, ..v })?
                }
                Adj::Deref => {
                    let Ty::Ref(d) = self.t.get(r.ty).clone() else { unreachable!() };
                    Val { ty: d, c: format!("(*({}))", r.c), lv: true, ..r }
                }
                Adj::Ref => {
                    let rt = self.t.intern(Ty::Ref(r.ty));
                    if r.lv {
                        Val { ty: rt, c: format!("(&({}))", r.c), lv: false, ..r }
                    } else if self.cx.keep_temps.is_some() {
                        // kept to the end of the statement (see keep_temps); its owner declares it, and an
                        // exit from the statement's scope deletes it from here on
                        let t = self.slot("_rv", r.ty);
                        let flag = self.flag_for(&t);
                        prefix.push_str(&format!("{t} = {}; {flag} = true; ", r.c));
                        if self.needs_drop(r.ty)? {
                            let drop = self.drop_fn(r.ty)?;
                            let s = self.cx.keep_scope;
                            self.cx.scopes[s].exits.push(Exit::Drop { c: t.clone(), drop, flag: flag.clone() });
                        }
                        self.cx.keep_temps.as_mut().unwrap().push((t.clone(), r.ty, flag));
                        Val::pure(rt, format!("(&{t})"))
                    } else {
                        let t = self.tmp("rv");
                        let tc = self.cty(r.ty);
                        prefix.push_str(&format!("{tc} {t} = {}; ", r.c));
                        if self.needs_drop(r.ty)? {
                            let d = self.drop_fn(r.ty)?;
                            post = format!("{d}(&{t});");
                        }
                        Val::pure(rt, format!("(&{t})"))
                    }
                }
            });
        }
        // the fixed arguments convert to their parameter types (comptime ones are part of the instance)
        let offset = vals.len();
        let fixed = f.params.len() - offset - f.pack as usize;
        for (i, a) in args.iter().enumerate().take(fixed) {
            let p = f.params[i + offset].clone();
            if p.comptime {
                continue; // baked into this instance
            }
            let v = match &pre[i] {
                Some(v) => v.clone(),
                None => self.expr(a, Some(p.ty))?,
            };
            let v = self.take_into(v, p.ty, a.span)?;
            self.note_arg(Body::Fn(inst), i + offset, v.ro, v.via, v.root.as_deref(), a.span, site);
            vals.push(v);
        }
        // the rest: one tuple for a pack, else C varargs
        if f.pack {
            let pt = f.params.last().unwrap().ty;
            let mut members: Vec<Val> = Vec::new();
            for (i, a) in args.iter().enumerate().skip(fixed) {
                members.push(match &pre[i] {
                    Some(v) => v.clone(),
                    None => self.expr(a, None)?,
                });
            }
            if pt == VOID {
                // empty pack: no argument
            } else {
                let tc = self.cty(pt);
                let inits: Vec<String> = members.iter().enumerate().map(|(i, v)| format!(".f{i} = {}", v.c)).collect();
                vals.push(Val::new(pt, format!("(({tc}){{ {} }})", inits.join(", "))));
            }
        } else if args.len() > fixed {
            for (i, a) in args.iter().enumerate().skip(fixed) {
                let v = match &pre[i] {
                    Some(v) => v.clone(),
                    None => self.expr(a, None)?,
                };
                vals.push(self.vararg_val(v, a.span)?);
            }
        }
        // parameters left out take their defaults, checked in the callee's env
        for p in f.params.iter().skip(offset + args.len().min(fixed)).take(fixed.saturating_sub(args.len())) {
            if p.comptime {
                continue;
            }
            let Some(d) = p.default.clone() else { return err(span, format!("missing argument '{}'", p.name)) };
            let ty = p.ty;
            vals.push(self.in_env(f.env.clone(), |c| c.expr_as(&d, ty))?);
        }
        self.use_fn(inst);
        self.warn_deprecated(inst, span);
        let seq = self.seq(&mut vals);
        let cs: Vec<String> = vals.iter().map(|v| v.c.clone()).collect();
        let (call, rty) = self.async_call(inst, format!("{}({})", f.c_name, cs.join(", ")), span)?;
        // an `async` call gives the frame, not the result
        let site = site.filter(|_| rty == f.ret);
        if !post.is_empty() {
            let rc = self.cty(rty);
            let code = if rty == VOID || rty == NEVER {
                format!("({{ {prefix}{seq}{call}; {post} }})")
            } else {
                format!("({{ {prefix}{seq}{rc} _cr = {call}; {post} _cr; }})")
            };
            return Ok(Self::site_result(Val::new(rty, code), site));
        }
        Ok(Self::site_result(Val::new(rty, Self::wrap_pre(&format!("{prefix}{seq}"), call)), site))
    }

    /// x.name(args): fn-typed field, trait-union dispatch, or an attached method
    pub fn method_call(&mut self, recv: Val, name: &str, gargs: &[GenericArg], args: &[Expr], want: Option<TyId>, span: Span) -> Res<Val> {
        if name == "delete" {
            return err(span, "delete runs by itself when the owner goes out of scope; it can't be called by hand");
        }
        if let Ty::Ptr(_) = self.t.get(recv.ty) {
            return err(span, format!("this is a pointer ({}); call through it with ->: p->{name}()", self.ty_name(recv.ty)));
        }
        let base = match self.t.get(recv.ty) {
            Ty::Ref(d) => *d,
            _ => recv.ty,
        };
        // an owning pointer (@owns, like std's box) is used like a T&: methods go to what it points at
        if let Some((pf, inner)) = self.owner(base) {
            let access = if base == recv.ty { format!("({}).{}", recv.c, c_field(&pf)) } else { format!("({})->{}", recv.c, c_field(&pf)) };
            let rt = self.t.intern(Ty::Ref(inner));
            return self.method_call(Val { pure: recv.pure, ..Val::new(rt, access) }, name, gargs, args, want, span);
        }
        if let Ty::Struct(sid) = self.t.get(base).clone() {
            let fields = self.struct_fields(sid, span)?;
            if fields.iter().any(|f| f.name == name && matches!(self.t.get(f.ty), Ty::FnPtr(..))) {
                let fv = self.field(recv, name, span)?;
                return self.call_value(fv, args, span);
            }
        }
        if let Ty::TraitUnion(u) = self.t.get(base).clone() {
            return self.union_call(recv, u, name, gargs, args, want, span);
        }
        let cands: Vec<DeclId> =
            self.attached.get(name).cloned().unwrap_or_default().into_iter().filter(|d| matches!(self.recv_of(*d), Recv::Val(_))).collect();
        if cands.is_empty() {
            return err(span, format!("{} has no method '{name}'", self.ty_name(recv.ty)));
        }
        self.resolve_call(name, &cands, Some(recv), None, gargs, args, want, span)
    }

    /// Type::name(args) for static attached fns
    pub fn static_call(&mut self, ty: TyId, name: &str, gargs: &[GenericArg], args: &[Expr], want: Option<TyId>, span: Span) -> Res<Val> {
        let cands: Vec<DeclId> =
            self.attached.get(name).cloned().unwrap_or_default().into_iter().filter(|d| matches!(self.recv_of(*d), Recv::Static(_))).collect();
        if cands.is_empty() {
            return err(span, format!("{} has no static function '{name}'", self.ty_name(ty)));
        }
        self.resolve_call(name, &cands, None, Some(ty), gargs, args, want, span)
    }

    /// an item's @intrinsic("name")
    fn intrinsic_of(&self, d: DeclId) -> Option<String> {
        self.decls[d].item.attrs.iter().find_map(|a| match &a.kind {
            ExprKind::Builtin(n, _, Some(args)) if n == "intrinsic" => match args.first() {
                Some(GenericArg::Expr(Expr { kind: ExprKind::Str(s), .. })) => Some(String::from_utf8_lossy(s).into_owned()),
                _ => None,
            },
            _ => None,
        })
    }

    // ---------- trait unions ----------

    /// The trait union for a trait, made once: every type a non-generic attach block attaches the
    /// trait to is a member. Fails if no type attaches it.
    pub fn trait_union(&mut self, trait_decl: DeclId, span: Span) -> Res<TyId> {
        if let Some(u) = self.union_ids.get(&trait_decl) {
            return Ok(self.t.intern(Ty::TraitUnion(*u)));
        }
        let name = self.decl_name(trait_decl);
        let id = self.unions.len() as u32;
        let c_name = self.fresh_c_name(&format!("v_{name}"));
        self.unions.push(UnionInfo { trait_decl, name: name.clone(), c_name, members: Vec::new() });
        self.union_ids.insert(trait_decl, id);
        let mut members = Vec::new();
        for b in self.attach_blocks.clone() {
            let item = self.decls[b].item.clone();
            let ns = self.decls[b].ns;
            let ItemKind::AttachBlock { trait_, target, .. } = &item.kind else { continue };
            if !item.generics.is_empty() || self.bound_trait(trait_, ns).map(|x| x.0) != Some(trait_decl) {
                continue;
            }
            let env = Rc::new(Env { ns, generics: Vec::new() });
            let t = self.resolve_type(target, &env)?;
            if !members.contains(&t) {
                members.push(t);
            }
        }
        if members.is_empty() {
            return err(span, format!("no type attaches {name}, so it can't be used as a type"));
        }
        self.unions[id as usize].members = members;
        Ok(self.t.intern(Ty::TraitUnion(id)))
    }

    /// member's index (its tag) in trait union ty, if it's one of its members
    pub fn union_member(&self, ty: TyId, member: TyId) -> Option<usize> {
        match self.t.get(ty) {
            Ty::TraitUnion(u) => self.unions[*u as usize].members.iter().position(|m| *m == member),
            _ => None,
        }
    }

    /// x.name() on a trait union: a switch on the tag that calls the method on each member type; the
    /// results coerce to the first member's result type
    #[allow(clippy::too_many_arguments)]
    fn union_call(&mut self, recv: Val, u: u32, name: &str, gargs: &[GenericArg], args: &[Expr], want: Option<TyId>, span: Span) -> Res<Val> {
        let uty = self.t.intern(Ty::TraitUnion(u));
        let uc = self.cty(uty);
        let up = self.tmp("u");
        let mut prefix = String::new();
        let ptr = if matches!(self.t.get(recv.ty), Ty::Ref(_)) {
            recv.c.clone()
        } else if recv.lv {
            format!("&({})", recv.c)
        } else {
            let t = self.tmp("uv");
            prefix = format!("{uc} {t} = {}; ", recv.c);
            format!("&{t}")
        };
        let members = self.unions[u as usize].members.clone();
        let mut cases = String::new();
        let mut rty: Option<TyId> = None;
        let r = self.tmp("ur");
        // one case runs, so moves are tracked per case as per match arm: each starts from the moves
        // before the call, and the code after sees them all
        let base = self.cx.moved.clone();
        let mut after = base.clone();
        for (i, m) in members.iter().enumerate() {
            self.cx.moved = base.clone();
            let mv = Val { lv: true, mutable: true, ..Val::pure(*m, format!("({up}->u.m{i})")) };
            let v = self.method_call(mv, name, gargs, args, rty.or(want), span)?;
            after.extend(self.cx.moved.iter().cloned());
            let v = match rty {
                None => {
                    rty = Some(v.ty);
                    v
                }
                Some(t) if v.ty == NEVER || t == VOID => v,
                Some(t) => self.coerce(v, t, span)?,
            };
            if matches!(rty, Some(VOID) | Some(NEVER)) || v.ty == NEVER {
                cases.push_str(&format!("case {i}: {}; break; ", v.c));
            } else {
                cases.push_str(&format!("case {i}: {r} = {}; break; ", v.c));
            }
        }
        self.cx.moved = after;
        let rty = rty.unwrap();
        let head = format!("{prefix}{uc}* {up} = {ptr};");
        if rty == VOID || rty == NEVER {
            return Ok(Val::new(VOID, format!("({{ {head} switch ({up}->tag) {{ {cases}}} }})")));
        }
        let rc = self.cty(rty);
        Ok(Val::new(rty, format!("({{ {head} {rc} {r}; switch ({up}->tag) {{ {cases}default: __builtin_unreachable(); }} {r}; }})")))
    }

    // ---------- Type::member paths ----------

    /// Type::name: a member of a type, or a variant of a generic enum written without its args
    pub fn member_path(&mut self, p: &Path) -> Res<Option<Member>> {
        if p.segs.len() < 2 {
            return Ok(None);
        }
        let prefix = Path { segs: p.segs[..p.segs.len() - 1].to_vec(), span: p.span };
        let env = self.cx.env.clone();
        if let Ok(ty) = self.resolve_type_path(&prefix, &env) {
            return Ok(Some(Member::Of(ty, p.last().to_string())));
        }
        let family = self.pattern_family(&prefix, env.ns);
        if let Some(d) = family {
            self.visible(d, p.span)?; // an internal type of another package: say so, not "unknown name"
        }
        // a generic enum written without its args: generic_enum::VALUE(1)
        if prefix.segs.last().unwrap().args.is_none() {
            if let Some(d) = family {
                if matches!(self.decls[d].item.kind, ItemKind::Enum(_)) && !self.decls[d].item.generics.is_empty() {
                    return Ok(Some(Member::GenericEnum(d, p.last().to_string())));
                }
            }
        }
        Ok(None)
    }

    /// pick the instance of a generic enum for a variant from the expected type or the payload
    pub fn infer_enum(&mut self, decl: DeclId, variant: &str, args: Option<&[Expr]>, want: Option<TyId>, span: Span) -> Res<TyId> {
        if let Some(w) = want {
            let inner = match self.t.get(w) {
                Ty::ErrUnion(e, _) => *e,
                Ty::Opt(i) => *i,
                _ => w,
            };
            if let Ty::Enum(e) = self.t.get(inner) {
                if self.enums[*e as usize].family == decl {
                    return Ok(inner);
                }
            }
        }
        let item = self.decls[decl].item.clone();
        let ns = self.decls[decl].ns;
        let ItemKind::Enum(e) = &item.kind else { unreachable!() };
        let gps = item.generics.clone();
        let mut binds = vec![None; gps.len()];
        let Some(v) = e.variants.iter().find(|v| v.name == variant) else { return err(span, format!("{} has no variant {variant}", e.name)) };
        // the payload is only checked here for its type; the real check (make_variant) comes later, so
        // moves made here are undone
        let moved_before = self.cx.moved.clone();
        if let (Some(pt), Some(args)) = (&v.payload, args) {
            if args.len() == 1 {
                let a = self.expr(&args[0], None)?;
                self.infer(pt, a.ty, &gps, &mut binds, ns);
            } else if let TypeKind::Tuple(ps) = &pt.kind {
                for ((_, p), a) in ps.iter().zip(args) {
                    let av = self.expr(a, None)?;
                    self.infer(p, av.ty, &gps, &mut binds, ns);
                }
            }
        }
        self.cx.moved = moved_before;
        let mut out = Vec::new();
        for (i, gp) in gps.iter().enumerate() {
            let env = self.partial_env(ns, &gps, &binds);
            let b = match binds[i].clone() {
                Some(b) => b,
                None => match &gp.default {
                    Some(d) => {
                        let kind = self.param_kind(gp, &env)?;
                        self.garg_gval(d, kind, &env)?
                    }
                    None => return err(span, format!("can't tell '{}' for {}; write {}<...>::{variant}", gp.name, e.name, e.name)),
                },
            };
            binds[i] = Some(b.clone());
            out.push(b);
        }
        self.enum_inst(decl, out, span)
    }
}
