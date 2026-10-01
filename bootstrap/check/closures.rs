// Closures. Each closure literal is a struct of its captures (its own type) with its own C
// function, so generics call it directly. fn(A) -> R is a fat {fn, env} pair that borrows a
// closure or wraps a plain function; nothing is allocated.
use super::*;

/// one closure literal: `c_name` is its capture struct, `fn_name` its body and `erased` the forwarder that
/// fn(...) values call
pub struct ClosureInfo {
    pub c_name: String,
    pub fn_name: String, // R f(struct*, params...)
    pub erased: String,  // R f(void*, params...), for fn(...) values
    /// each capture's field name and stored type (T& for a `&` capture, else T)
    pub caps: Vec<(String, TyId)>,
    pub params: Vec<TyId>,
    pub ret: TyId,
    /// its params' names, then its captures' (lends.rs counts captures as parameters after its own)
    pub names: Vec<String>,
}

impl Checker {
    /// a closure literal: emits its body as a C function and returns the capture struct's value. Untyped
    /// params and the return type come from `want` when it is a fn(...) type
    #[allow(clippy::too_many_arguments)]
    pub fn closure_expr(&mut self, caps: &[Capture], params: &[Param], ret: Option<&Type>, body: &Block, want: Option<TyId>, span: Span) -> Res<Val> {
        let env = self.cx.env.clone();
        let want_sig = match want.map(|w| self.t.get(w).clone()) {
            Some(Ty::FnVal(ps, r)) => Some((ps, r)),
            _ => None,
        };
        if let Some((ps, _)) = &want_sig {
            if ps.len() != params.len() {
                return err(span, format!("expected a closure taking {} parameters, this one takes {}", ps.len(), params.len()));
            }
        }
        let mut ptys = Vec::new();
        for (i, p) in params.iter().enumerate() {
            ptys.push(match (&p.ty, &want_sig) {
                (Some(t), _) => self.resolve_type(t, &env)?,
                (None, Some((ps, _))) => ps[i],
                (None, None) => return err(p.span, "closure parameter needs a type here: (x: i32)"),
            });
        }
        let rty = match (ret, &want_sig) {
            (Some(t), _) => self.resolve_type(t, &env)?,
            (None, Some((_, r))) => *r,
            (None, None) => VOID,
        };
        // captures: (name, stored type, C initializer, type inside the body, C access, mutable)
        let mut stored = Vec::new();
        let mut inits = Vec::new();
        let mut inner = Vec::new();
        for c in caps {
            let Some(l) = self.lookup_local(&c.name) else { return err(c.span, format!("no local '{}' to capture", c.name)) };
            if self.cx.moved.contains(&l.c) {
                let d = Diag::new(c.span, format!("'{}' was moved earlier, so it can't be captured", c.name));
                return Err(match self.cx.move_sites.get(&l.c) {
                    Some(at) => d.label(*at, "moved here"),
                    None => d,
                });
            }
            let v = Val { lv: true, mutable: l.mutable, owner: l.flag.as_ref().map(|_| c.name.clone()), ..Val::pure(l.ty, l.c.clone()) };
            let (fty, init, access, mutable) = match c.mode {
                CapMode::Ref => (self.t.intern(Ty::Ref(l.ty)), format!("&({})", l.c), format!("(*env->{})", c_field(&c.name)), l.mutable),
                CapMode::Move => (l.ty, self.take(v, c.span)?.c, format!("(env->{})", c_field(&c.name)), true),
                CapMode::Copy => (l.ty, self.copy_val(v, c.span)?.c, format!("(env->{})", c_field(&c.name)), true),
            };
            stored.push((c.name.clone(), fty));
            inits.push(format!(".{} = {init}", c_field(&c.name)));
            inner.push((c.name.clone(), l.ty, access, mutable, l.clone()));
        }
        // the closure's own type, and the names of its two C functions
        let id = self.closures.len() as u32;
        let c_name = self.fresh_c_name("volt_closure");
        let (fn_name, erased) = (format!("{c_name}_fn"), format!("{c_name}_erased"));
        let names = params.iter().map(|p| p.name.clone()).chain(caps.iter().map(|c| c.name.clone())).collect();
        self.closures.push(ClosureInfo { c_name: c_name.clone(), fn_name: fn_name.clone(), erased: erased.clone(), caps: stored, params: ptys.clone(), ret: rty, names });
        // a captured reference reaching through one of ours is passed on to the closure
        for (ci, (_, t, _, _, l)) in inner.iter().enumerate() {
            if let (Some((k, off)), Some(b)) = (l.via, self.cx.body) {
                if self.reaches(*t) {
                    self.edges.push((b, k as usize, off, Body::Closure(id), params.len() + ci));
                }
            }
        }
        let ty = self.t.intern(Ty::Closure(id));
        self.cty(ty); // registers the capture struct for emission

        // the body is its own C function; it sees its captures and params, not the outer locals
        let mut fresh = FnCx::new(rty, env.clone());
        fresh.body = Some(Body::Closure(id));
        let saved = std::mem::replace(&mut self.cx, fresh);
        let r = (|| -> Res<(String, String)> {
            for (ci, (name, t, access, mutable, l)) in inner.iter().enumerate() {
                let via = self.reaches(*t).then_some(((params.len() + ci) as u32, 0));
                self.cx.scopes[0].vars.insert(name.clone(), Local { c: access.clone(), ty: *t, mutable: *mutable, orig: None, flag: None, loops: 0, ro: l.ro, via, root: Some(name.clone()), param: l.param });
            }
            // params are locals of the body; a param that needs a drop gets a live flag, like any owned local
            let mut flags = String::new();
            let mut sig = Vec::new();
            for (i, (p, t)) in params.iter().zip(&ptys).enumerate() {
                let c = format!("{}_{i}", p.name);
                let via = self.reaches(*t).then_some((i as u32, 0));
                let mut local = Local { c: c.clone(), ty: *t, mutable: p.mutable, orig: None, flag: None, loops: 0, ro: 0, via, root: Some(p.name.clone()), param: true };
                if self.needs_drop(*t)? {
                    let flag = format!("{c}_live");
                    flags.push_str(&format!("bool {flag} = true; "));
                    let drop = self.drop_fn(*t)?;
                    self.cx.scopes[0].exits.push(Exit::Drop { c: c.clone(), drop, flag: flag.clone() });
                    local.flag = Some(flag);
                }
                self.cx.scopes[0].vars.insert(p.name.clone(), local);
                let tc = self.cty(*t);
                sig.push(format!("{tc} {c}"));
            }
            let (code, div) = self.block_code(body)?;
            if !div && rty != VOID {
                return err(body.span, format!("this closure can reach its end without returning a {}", self.ty_name(rty)));
            }
            let at_end = if div { String::new() } else { self.scope_exit_code(0, 0, false)? };
            Ok((format!("{{ {flags}{code} {at_end}}}"), sig.join(", ")))
        })();
        self.cx = saved;
        let (code, sig) = r?;
        // emit both functions: the typed body, and the erased one that casts env back and forwards
        let rc = if rty == NEVER { "void".to_string() } else { self.cty(rty) };
        let sep = if sig.is_empty() { "" } else { ", " };
        let names: Vec<String> = params.iter().enumerate().map(|(i, p)| format!("{}_{i}", p.name)).collect();
        let fwd = names.join(", ");
        self.protos.push_str(&format!("static {rc} {fn_name}({c_name}* env{sep}{sig});\nstatic {rc} {erased}(void* env{sep}{sig});\n"));
        self.bodies.push_str(&format!("static {rc} {fn_name}({c_name}* env{sep}{sig}) {code}\n"));
        let ret_kw = if rty == VOID || rty == NEVER { "" } else { "return " };
        self.bodies.push_str(&format!("static {rc} {erased}(void* env{sep}{sig}) {{ {ret_kw}{fn_name}(({c_name}*)env{sep}{fwd}); }}\n\n"));
        let init = if inits.is_empty() { "0".to_string() } else { inits.join(", ") };
        Ok(Val::new(ty, format!("(({c_name}){{ {init} }})")))
    }

    /// a plain function as a fn(...) value: {trampoline, null}
    /// (the trampoline is emitted once per fn instance and ignores env)
    pub fn fn_value(&mut self, inst: usize, fv: TyId) -> String {
        let f = self.fns[inst].clone();
        let name = format!("{}_tramp", f.c_name);
        {
            {
                if !self.used_c_names.contains_key(&name) {
                    self.used_c_names.insert(name.clone(), 1);
                    let rc = if f.ret == NEVER { "void".to_string() } else { self.cty(f.ret) };
                    let mut sig = Vec::new();
                    let mut names = Vec::new();
                    for (i, p) in f.params.iter().enumerate().filter(|(_, p)| !p.comptime && p.ty != VOID) {
                        let tc = self.cty(p.ty);
                        sig.push(format!("{tc} a{i}"));
                        names.push(format!("a{i}"));
                    }
                    let sep = if sig.is_empty() { "" } else { ", " };
                    self.glue_protos.push_str(&format!("static {rc} {name}(void* env{sep}{});\n", sig.join(", ")));
                    let ret = if f.ret == VOID || f.ret == NEVER { "" } else { "return " };
                    self.glue.push_str(&format!("static {rc} {name}(void* env{sep}{}) {{ {ret}{}({}); }}\n", sig.join(", "), f.c_name, names.join(", ")));
                }
            }
        }
        let tc = self.cty(fv);
        format!("(({tc}){{ .fn = {name}, .env = 0 }})")
    }

    /// closure -> fn(...) value: borrows the closure's storage
    /// (the caller makes sure v is a variable or a closure literal, so its address can be taken)
    pub fn closure_to_fn(&mut self, v: &Val, fv: TyId) -> Res<String> {
        let Ty::Closure(id) = self.t.get(v.ty).clone() else { unreachable!() };
        let tc = self.cty(fv);
        let erased = self.closures[id as usize].erased.clone();
        self.escape(Body::Closure(id), fv);
        Ok(format!("(({tc}){{ .fn = {erased}, .env = (void*)&({}) }})", v.c))
    }

    /// a closure type's (params, ret), or None for any other type
    pub fn closure_sig(&self, ty: TyId) -> Option<(Vec<TyId>, TyId)> {
        match self.t.get(ty) {
            Ty::Closure(id) => {
                let c = &self.closures[*id as usize];
                Some((c.params.clone(), c.ret))
            }
            _ => None,
        }
    }
}
