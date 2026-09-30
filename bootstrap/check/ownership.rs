// Ownership: which types need delete, generated drop/copy glue, moves out of locals, and box.
// A type needs delete if it attaches `delete`, is a box, or contains such a type. Owned locals get
// a runtime "live" flag, so conditional moves are handled; scope exits drop live owners in reverse.
use super::*;

impl Checker {
    /// an @owns struct: (its pointer field, what it owns)
    pub fn owner(&self, ty: TyId) -> Option<(String, TyId)> {
        let Ty::Struct(s) = self.t.get(ty) else { return None };
        self.structs[*s as usize].owns.clone()
    }

    /// what an @owns struct (like std's box) points at
    pub fn box_inner(&self, ty: TyId) -> Option<TyId> {
        self.owner(ty).map(|o| o.1)
    }

    /// whether a value of ty must be deleted: it has a delete hook, is an @owns box, or holds such a value
    /// (memoized)
    pub fn needs_drop(&mut self, ty: TyId) -> Res<bool> {
        if let Some(b) = self.drop_memo.get(&ty) {
            return Ok(*b);
        }
        self.drop_memo.insert(ty, false); // recursion through a box is fine: box already says yes
        match self.needs_drop_uncached(ty) {
            Ok(r) => {
                self.drop_memo.insert(ty, r);
                Ok(r)
            }
            Err(e) => {
                // not an answer: the next function to ask (the run goes on after an error) tries again
                self.drop_memo.remove(&ty);
                Err(e)
            }
        }
    }

    fn needs_drop_uncached(&mut self, ty: TyId) -> Res<bool> {
        let r = match self.t.get(ty).clone() {
            Ty::Struct(s) => {
                if self.box_inner(ty).is_some() || self.hook(ty, "delete")?.is_some() {
                    true
                } else {
                    let fields = self.struct_fields(s, Span::default())?;
                    let mut any = false;
                    for f in fields.iter() {
                        any |= self.needs_drop(f.ty)?;
                    }
                    any
                }
            }
            Ty::Enum(e) => {
                let mut any = self.hook(ty, "delete")?.is_some();
                for p in self.enum_payloads(e, Span::default())?.iter().flatten() {
                    any |= self.needs_drop(*p)?;
                }
                any
            }
            Ty::Tuple(ts, _) => {
                let mut any = false;
                for t in ts {
                    any |= self.needs_drop(t)?;
                }
                any
            }
            Ty::Array(t, _) | Ty::Opt(t) => self.needs_drop(t)?,
            Ty::ErrUnion(e, t) => self.needs_drop(e)? || self.needs_drop(t)?,
            Ty::Closure(c) => {
                let mut any = false;
                for (_, t) in self.closures[c as usize].caps.clone() {
                    any |= self.needs_drop(t)?;
                }
                any
            }
            Ty::TraitUnion(u) => {
                let mut any = false;
                for m in self.unions[u as usize].members.clone() {
                    any |= self.needs_drop(m)?;
                }
                any
            }
            Ty::Frame(_) => true, // an unfinished frame is cancelled; a finished one may hold its result
            _ => false,
        };
        Ok(r)
    }

    /// an attached `delete(this: T&)` or `copy(this: T&) -> T` for this exact type
    /// (or `as_str(this: T&) -> str`); the fn instance, memoized
    pub fn hook(&mut self, ty: TyId, name: &'static str) -> Res<Option<usize>> {
        if let Some(h) = self.hook_memo.get(&(ty, name)) {
            return Ok(*h);
        }
        self.hook_memo.insert((ty, name), None);
        let rt = self.t.intern(Ty::Ref(ty));
        let recv = Val::pure(rt, "p");
        // write_str takes the text too
        let args = if name == "write_str" { vec![Some(Val::pure(STR, "s"))] } else { Vec::new() };
        let r = (|| -> Res<Option<usize>> {
            for d in self.attached.get(name).cloned().unwrap_or_default() {
                if let Ok((binds, generics::Adj::None)) = self.bind_cand(d, Some(&recv), None, &[], &args)? {
                    let i = self.fn_inst(d, binds, Span::default())?;
                    let writes = self.fns[i].ret == VOID && self.fns[i].params.len() == 2 && self.fns[i].params[1].ty == STR;
                    let yields = matches!(self.t.get(self.fns[i].ret), Ty::Opt(_) | Ty::Ptr(_));
                    if (name == "copy" && self.fns[i].ret != ty) || (name == "as_str" && self.fns[i].ret != STR) || (name == "write_str" && !writes) || (name == "next" && !yields) {
                        continue;
                    }
                    return Ok(Some(i));
                }
            }
            Ok(None)
        })();
        match r {
            Ok(found) => {
                self.hook_memo.insert((ty, name), found);
                Ok(found)
            }
            Err(e) => {
                // not an answer: the next function to ask (the run goes on after an error) tries again
                self.hook_memo.remove(&(ty, name));
                Err(e)
            }
        }
    }

    /// name of the C function that deletes a value in place: void f(T*)
    /// (made once per type. A struct drops an @owns pointee, then runs its delete hook, then drops its fields
    /// in reverse)
    pub fn drop_fn(&mut self, ty: TyId) -> Res<String> {
        if let Some(n) = self.glue_names.get(&(ty, "drop")) {
            return Ok(n.clone());
        }
        let name = format!("volt_drop_{ty}");
        self.glue_names.insert((ty, "drop"), name.clone());
        let tc = self.cty(ty);
        let mut body = String::new();
        match self.t.get(ty).clone() {
            Ty::Struct(s) => {
                if let Some((pf, inner)) = self.owner(ty) {
                    if self.needs_drop(inner)? {
                        let d = self.drop_fn(inner)?;
                        body.push_str(&format!("{d}(p->{}); ", c_field(&pf)));
                    }
                }
                if let Some(h) = self.hook(ty, "delete")? {
                    self.use_fn(h);
                    body.push_str(&format!("{}(p); ", self.fns[h].c_name));
                }
                let fields = self.struct_fields(s, Span::default())?;
                for f in fields.iter().rev() {
                    if self.needs_drop(f.ty)? {
                        let d = self.drop_fn(f.ty)?;
                        body.push_str(&format!("{d}(&p->{}); ", c_field(&f.name)));
                    }
                }
            }
            Ty::Enum(e) => {
                if let Some(h) = self.hook(ty, "delete")? {
                    self.use_fn(h);
                    body.push_str(&format!("{}(p); ", self.fns[h].c_name));
                }
                let payloads = self.enum_payloads(e, Span::default())?;
                let (values, tag) = (self.enums[e as usize].values.clone(), self.enums[e as usize].tag);
                let mut cases = String::new();
                for (i, p) in payloads.iter().enumerate() {
                    if let Some(pt) = p {
                        if self.needs_drop(*pt)? {
                            let d = self.drop_fn(*pt)?;
                            let v = self.c_int(values[i], int(tag));
                            cases.push_str(&format!("case {v}: {d}(&p->u.v{i}); break; "));
                        }
                    }
                }
                if !cases.is_empty() {
                    body.push_str(&format!("switch (p->tag) {{ {cases}default: break; }} "));
                }
            }
            Ty::Tuple(ts, _) => {
                for (i, t) in ts.iter().enumerate().rev() {
                    if self.needs_drop(*t)? {
                        let d = self.drop_fn(*t)?;
                        body.push_str(&format!("{d}(&p->f{i}); "));
                    }
                }
            }
            Ty::Closure(c) => {
                for (n, t) in self.closures[c as usize].caps.clone().iter().rev() {
                    if self.needs_drop(*t)? {
                        let d = self.drop_fn(*t)?;
                        body.push_str(&format!("{d}(&p->{}); ", c_field(n)));
                    }
                }
            }
            Ty::Array(t, n) => {
                let d = self.drop_fn(t)?;
                body.push_str(&format!("for (size_t i = {n}; i-- > 0;) {d}(&p->a[i]); "));
            }
            Ty::Opt(t) => {
                let d = self.drop_fn(t)?;
                body.push_str(&format!("if (p->has) {d}(&p->v); "));
            }
            Ty::ErrUnion(e, t) => {
                let code = self.eu_code(ty, "(*p)");
                if self.needs_drop(t)? {
                    let d = self.drop_fn(t)?;
                    body.push_str(&format!("if (!{code}) {d}(&p->v); "));
                }
                if self.needs_drop(e)? {
                    let d = self.drop_fn(e)?;
                    body.push_str(&format!("if ({code}) {d}(&p->err); "));
                }
            }
            Ty::TraitUnion(u) => {
                let mut cases = String::new();
                for (i, m) in self.unions[u as usize].members.clone().into_iter().enumerate() {
                    if self.needs_drop(m)? {
                        let d = self.drop_fn(m)?;
                        cases.push_str(&format!("case {i}: {d}(&p->u.m{i}); break; "));
                    }
                }
                body.push_str(&format!("switch (p->tag) {{ {cases}default: break; }} "));
            }
            // an unfinished frame is stepped once with cancel set, so it runs its own cleanup
            Ty::Frame(i) => {
                let (x, ret) = (self.fns[i as usize].c_name.clone(), self.fns[i as usize].ret);
                body.push_str(&format!("if (p->state < VOLT_DONE) {{ p->cancel = 1; {x}_step(p); }} "));
                if self.needs_drop(ret)? {
                    let d = self.drop_fn(ret)?;
                    body.push_str(&format!("else if (p->state == VOLT_DONE) {d}(&p->ret); "));
                }
            }
            _ => {}
        }
        self.glue_protos.push_str(&format!("static void {name}({tc}* p);\n"));
        self.glue.push_str(&format!("static void {name}({tc}* p) {{ {body}}}\n"));
        Ok(name)
    }

    /// name of the C function that deep-copies: T f(T*)
    /// (made once per type: the copy hook if there is one, else a bitwise copy with each owning part copied
    /// again. An @owns box without a copy hook can't be copied)
    pub fn copy_fn(&mut self, ty: TyId, span: Span) -> Res<String> {
        if let Some(n) = self.glue_names.get(&(ty, "copy")) {
            return Ok(n.clone());
        }
        if let Ty::Frame(_) = self.t.get(ty) {
            return err(span, "a frame can't be copied");
        }
        // copying the bytes of something that deletes itself would delete it twice
        if self.hook(ty, "copy")?.is_none() && self.hook(ty, "delete")?.is_some() {
            return err(span, format!("can't copy {}: it attaches delete but not copy, so both copies would delete the same thing; attach fn copy(this: T&) -> T", self.ty_name(ty)));
        }
        let name = format!("volt_copy_{ty}");
        self.glue_names.insert((ty, "copy"), name.clone());
        let tc = self.cty(ty);
        let mut body = format!("{tc} r = *p; ");
        if let Some(h) = self.hook(ty, "copy")? {
            self.use_fn(h);
            body = format!("{tc} r = {}(p); ", self.fns[h].c_name);
        } else {
            let sub = |c: &mut Self, t: TyId, place: &str, body: &mut String| -> Res<()> {
                if c.needs_drop(t)? {
                    let f = c.copy_fn(t, span)?;
                    body.push_str(&format!("r.{place} = {f}(&p->{place}); "));
                }
                Ok(())
            };
            match self.t.get(ty).clone() {
                Ty::Struct(s) => {
                    if self.box_inner(ty).is_some() {
                        // an owning pointer's copy needs its allocator, which only the library knows
                        return err(span, format!("can't copy {}: attach a copy fn for it: attach fn copy(this: T&) -> T", self.ty_name(ty)));
                    } else {
                        for f in self.struct_fields(s, span)?.iter() {
                            sub(self, f.ty, &c_field(&f.name), &mut body)?;
                        }
                    }
                }
                Ty::Tuple(ts, _) => {
                    for (i, t) in ts.iter().enumerate() {
                        sub(self, *t, &format!("f{i}"), &mut body)?;
                    }
                }
                Ty::Closure(c) => {
                    for (n, t) in self.closures[c as usize].caps.clone() {
                        sub(self, t, &c_field(&n), &mut body)?;
                    }
                }
                Ty::Array(t, n) => {
                    if self.needs_drop(t)? {
                        let f = self.copy_fn(t, span)?;
                        body.push_str(&format!("for (size_t i = 0; i < {n}; i++) r.a[i] = {f}(&p->a[i]); "));
                    }
                }
                Ty::Opt(t) => {
                    if self.needs_drop(t)? {
                        let f = self.copy_fn(t, span)?;
                        body.push_str(&format!("if (p->has) r.v = {f}(&p->v); "));
                    }
                }
                Ty::ErrUnion(e, t) => {
                    let code = self.eu_code(ty, "(*p)");
                    if self.needs_drop(t)? {
                        let f = self.copy_fn(t, span)?;
                        body.push_str(&format!("if (!{code}) r.v = {f}(&p->v); "));
                    }
                    if self.needs_drop(e)? {
                        let f = self.copy_fn(e, span)?;
                        body.push_str(&format!("if ({code}) r.err = {f}(&p->err); "));
                    }
                }
                Ty::Enum(e) => {
                    let payloads = self.enum_payloads(e, span)?;
                    let (values, tag) = (self.enums[e as usize].values.clone(), self.enums[e as usize].tag);
                    let mut cases = String::new();
                    for (i, p) in payloads.iter().enumerate() {
                        if let Some(pt) = p {
                            if self.needs_drop(*pt)? {
                                let f = self.copy_fn(*pt, span)?;
                                let v = self.c_int(values[i], int(tag));
                                cases.push_str(&format!("case {v}: r.u.v{i} = {f}(&p->u.v{i}); break; "));
                            }
                        }
                    }
                    // a payload-less enum is a plain integer (no tag field), and there's nothing to copy
                    if !cases.is_empty() {
                        body.push_str(&format!("switch (p->tag) {{ {cases}default: break; }} "));
                    }
                }
                Ty::TraitUnion(u) => {
                    let mut cases = String::new();
                    for (i, m) in self.unions[u as usize].members.clone().into_iter().enumerate() {
                        if self.needs_drop(m)? {
                            let f = self.copy_fn(m, span)?;
                            cases.push_str(&format!("case {i}: r.u.m{i} = {f}(&p->u.m{i}); break; "));
                        }
                    }
                    body.push_str(&format!("switch (p->tag) {{ {cases}default: break; }} "));
                }
                _ => {}
            }
        }
        self.glue_protos.push_str(&format!("static {tc} {name}({tc}* p);\n"));
        self.glue.push_str(&format!("static {tc} {name}({tc}* p) {{ {body}return r; }}\n"));
        Ok(name)
    }

    /// Use a value by value (let, assignment, argument, return, literal member...). An owned
    /// local of a type that needs delete is moved: its flag clears so its scope won't delete it.
    pub fn take(&mut self, v: Val, span: Span) -> Res<Val> {
        if !v.lv || !self.needs_drop(v.ty)? {
            return Ok(v);
        }
        if let Ty::Frame(_) = self.t.get(v.ty) {
            return err(span, "a frame can't move (it may point into itself); resume or await it where it is");
        }
        let Some(name) = v.owner.clone() else {
            return err(span, format!("can't move a {} out of a field, element or reference; copy it instead: copy x", self.ty_name(v.ty)));
        };
        let l = self.lookup_local(&name).unwrap();
        let loops_now = self.cx.loops.iter().filter(|l| !l.is_block).count();
        if l.loops < loops_now && self.cx.exiting == 0 && self.cx.reassigning.as_deref() != Some(l.c.as_str()) {
            return err(span, format!("can't move '{name}' inside a loop (the next time around it would already be gone); move it before the loop, or return/break right after"));
        }
        self.cx.moved.insert(l.c.clone());
        self.cx.move_sites.insert(l.c.clone(), span);
        let flag = l.flag.unwrap();
        Ok(Val { c: format!("({{ {flag} = false; {}; }})", v.c), lv: false, pure: false, owner: None, mutable: false, ..v })
    }

    /// take(v) then convert to `to`; a box handed to a T* is only borrowed, not moved
    pub fn take_into(&mut self, v: Val, to: TyId, span: Span) -> Res<Val> {
        let borrow = matches!(self.t.get(to), Ty::Ref(t) | Ty::Ptr(t) if self.box_inner(v.ty) == Some(*t));
        let v = if borrow { v } else { self.take(v, span)? };
        self.coerce(v, to, span)
    }

    /// a copy of v the caller owns: v itself when nothing needs deleting or it's a temporary, else a deep
    /// copy
    pub fn copy_val(&mut self, v: Val, span: Span) -> Res<Val> {
        if !self.needs_drop(v.ty)? {
            return Ok(Val { owner: None, ..v });
        }
        if !v.lv {
            return Ok(v); // a temporary is already a fresh value
        }
        let f = self.copy_fn(v.ty, span)?;
        Ok(Val::new(v.ty, format!("{f}(&({}))", v.c)))
    }

    /// declare an owned local; returns (C name, extra C code declaring its live flag)
    pub fn owned_local(&mut self, name: &str, ty: TyId, mutable: bool) -> Res<(String, String)> {
        let c = self.new_local(name, ty, mutable);
        if !self.needs_drop(ty)? {
            return Ok((c, String::new()));
        }
        let flag = self.flag_for(&c);
        let drop = self.drop_fn(ty)?;
        let scope = self.cx.scopes.last_mut().unwrap();
        scope.vars.get_mut(name).unwrap().flag = Some(flag.clone());
        scope.exits.push(Exit::Drop { c: c.clone(), drop, flag: flag.clone() });
        Ok((c, format!(" {};", Self::decl("bool", &flag, "true"))))
    }

    /// a statement's discarded value: delete it if it's a temporary that owns something
    pub fn discard(&mut self, v: Val) -> Res<String> {
        if v.ty == VOID || v.ty == NEVER || v.lv || !self.needs_drop(v.ty)? {
            return Ok(v.c);
        }
        let tc = self.cty(v.ty);
        let d = self.drop_fn(v.ty)?;
        Ok(format!("({{ {tc} _d = {}; {d}(&_d); }})", v.c))
    }
}
