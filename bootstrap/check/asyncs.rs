// Async fns are stackless state machines, with no scheduler and no heap. `async fn f` becomes a
// frame struct (resume state, result, and every param/local/loop counter that may live across a
// suspend) plus `bool f_step(frame*)`, which runs to the next suspend (false) or the end (true).
// `val fr = async f()` builds the frame in place and runs it to its first suspend, `resume fr`
// steps once, `await fr` steps until done and takes the result. A plain call (or `await f()`)
// runs a temporary frame to completion. Frames never move: they may point into themselves.
// Deleting an unfinished frame resumes it in cancel mode, which runs its defers and deletes.
use super::*;
use std::collections::HashSet;

impl Checker {
    pub fn is_async_fn(&self, idx: usize) -> bool {
        matches!(&self.decls[self.fns[idx].decl].item.kind, ItemKind::Fn(f) if f.is_async)
    }

    /// a C place for a local: a frame field inside an async fn, a C local otherwise
    pub fn field_c(&mut self, name: String, ty: TyId) -> String {
        match self.cx.frame {
            Some(i) => {
                self.frames.get_mut(&i).unwrap().push((name.clone(), ty));
                format!("_f->{name}")
            }
            None => name,
        }
    }

    /// a fresh statement-level C variable that may live across a suspend
    pub fn slot(&mut self, base: &str, ty: TyId) -> String {
        self.cx.next_id += 1;
        // a hidden local's Volt name starts with @ (no source can name it); its C name drops that
        let name = format!("{}_{}", base.trim_start_matches('@'), self.cx.next_id);
        self.field_c(name, ty)
    }

    /// the "still live" flag of an owned local
    pub fn flag_for(&mut self, c: &str) -> String {
        if let (Some(raw), Some(i)) = (c.strip_prefix("_f->"), self.cx.frame) {
            self.frames.get_mut(&i).unwrap().push((format!("{raw}_live"), BOOL));
        }
        format!("{c}_live")
    }

    /// temporary r kept to the end of the statement (see keep_temps): its slot, which the code pushed
    /// on prefix sets; its owner declares it, and an exit from the statement's scope deletes it from here on
    pub fn keep_temp(&mut self, r: &Val, prefix: &mut String) -> Res<String> {
        let t = self.slot("_rv", r.ty);
        let flag = self.flag_for(&t);
        prefix.push_str(&format!("{t} = {}; {flag} = true; ", r.c));
        if self.needs_drop(r.ty)? {
            let drop = self.drop_fn(r.ty)?;
            let s = self.cx.keep_scope;
            self.cx.scopes[s].exits.push(Exit::Drop { c: t.clone(), drop, flag: flag.clone() });
        }
        self.cx.keep_temps.as_mut().unwrap().push((t.clone(), r.ty, flag));
        Ok(t)
    }

    /// `T c = init` for a C local, `c = init` for a frame field
    pub fn decl(cty: &str, c: &str, init: &str) -> String {
        if c.starts_with("_f->") { format!("{c} = {init}") } else { format!("{cty} {c} = {init}") }
    }

    /// leave the function with `val` (already of the return type) after running `defers`
    pub fn fn_exit(&mut self, val: Option<String>, defers: &str) -> String {
        let ret = self.cx.ret;
        if self.cx.frame.is_some() {
            let set = match val {
                Some(v) if ret == VOID => format!("{v}; "),
                Some(v) => format!("_f->ret = {v}; "),
                None => String::new(),
            };
            return format!("{{ {set}{defers}_f->state = VOLT_DONE; return true; }}");
        }
        match val {
            Some(v) if ret == VOID => format!("{{ {v}; {defers}return; }}"),
            Some(v) if defers.is_empty() => format!("return {v}"),
            Some(v) => {
                let c = self.cty(ret);
                format!("{{ {c} _ret = {v}; {defers}return _ret; }}")
            }
            None => format!("{{ {defers}return; }}"),
        }
    }

    /// where fn_exit keeps the return value while defers run
    pub fn ret_slot(&self) -> &'static str {
        if self.cx.frame.is_some() { "(_f->ret)" } else { "_ret" }
    }

    /// `suspend;`: records resume point n and returns false from the step fn; the step fn's switch jumps back
    /// to label volt_s<n>. A frame cancelled while stopped here runs its cleanup and finishes instead
    pub fn suspend(&mut self, span: Span) -> Res<String> {
        if self.cx.frame.is_none() {
            return err(span, "suspend only works inside an async fn");
        }
        if self.cx.no_suspend > 0 {
            return err(span, "suspend can't be inside a defer");
        }
        self.cx.suspends.push(span);
        let n = self.cx.suspends.len();
        // cancelled here (deleted before finishing): leave like a return, without a value
        let top = self.cx.scopes.len() - 1;
        let cleanup = self.scope_exit_code(top, 0, false)?;
        Ok(format!("{{ _f->state = {n}; return false; volt_s{n}:; if (_f->cancel) {{ {cleanup}_f->state = VOLT_TAKEN; return true; }} }}"))
    }

    /// a pointer to the frame `e` names, and its fn instance
    fn frame_ptr(&mut self, e: &Expr, what: &str) -> Res<(String, usize)> {
        let v = self.expr(e, None)?;
        match self.t.get(v.ty).clone() {
            Ty::Frame(i) if v.lv => return Ok((format!("(&({}))", v.c), i as usize)),
            Ty::Ref(t) | Ty::Ptr(t) => {
                if let Ty::Frame(i) = self.t.get(t).clone() {
                    return Ok((v.c, i as usize));
                }
            }
            _ => {}
        }
        err(e.span, format!("{what} needs a frame (val fr = async f()), found {}", self.ty_name(v.ty)))
    }

    /// `resume fr;`: steps the frame once; a frame that already finished panics
    pub fn resume(&mut self, e: &Expr, span: Span) -> Res<String> {
        let (p, i) = self.frame_ptr(e, "resume")?;
        let fc = self.frame_cty(i);
        let x = self.fns[i].c_name.clone();
        let loc = self.loc(span);
        Ok(format!("{{ {fc}* _p = {p}; if (_p->state >= VOLT_DONE) volt_panic(\"resumed a frame that already finished\", \"{loc}\"); {x}_step(_p); }}"))
    }

    /// `await fr` steps the frame to its end and takes the result; `await f()` is a checked plain call
    pub fn await_expr(&mut self, e: &Expr, want: Option<TyId>) -> Res<Val> {
        if let ExprKind::Call(..) = &e.kind {
            let v = self.marked_call(e, want, false)?;
            return Ok(v);
        }
        let (p, i) = self.frame_ptr(e, "await")?;
        let x = self.fns[i].c_name.clone();
        Ok(Val::new(self.fns[i].ret, format!("{x}_await({p})")))
    }

    /// check a call that must reach an async fn: started (a frame) or awaited (its result)
    fn marked_call(&mut self, call: &Expr, want: Option<TyId>, start: bool) -> Res<Val> {
        // call_mode stays set until async_call claims this call by its span; still set afterwards means the
        // call never reached an async fn
        let saved = self.cx.call_mode.replace((call.span, start));
        let v = self.expr(call, want);
        let missed = std::mem::replace(&mut self.cx.call_mode, saved).is_some();
        let v = v?;
        if missed {
            let what = if start { "async" } else { "await" };
            return err(call.span, format!("{what} needs a call to an async fn"));
        }
        Ok(v)
    }

    /// emit_call's hook: how a call to `inst` at `span` is lowered. Returns the C call and its type.
    /// A call to an async fn runs a temporary frame to completion (f_run), unless it's marked `async`: then
    /// it gives the frame itself
    pub fn async_call(&mut self, inst: usize, call: String, span: Span) -> Res<(String, TyId)> {
        let mode = match self.cx.call_mode {
            Some((s, m)) if s == span => {
                self.cx.call_mode = None;
                Some(m)
            }
            _ => None,
        };
        let f = &self.fns[inst];
        if !self.is_async_fn(inst) {
            if mode.is_some() {
                return err(span, format!("'{}' isn't an async fn", f.name));
            }
            return Ok((call, f.ret));
        }
        if mode == Some(true) {
            return Ok((call, self.t.intern(Ty::Frame(inst as u32))));
        }
        Ok((format!("{}_run({call})", f.c_name), f.ret))
    }

    /// `val fr = async f(args)`: build the frame in place, then run it to its first suspend
    pub fn async_let(&mut self, l: &Let, call: &Expr) -> Res<(String, bool)> {
        let PatKind::Bind(name) = &l.pat.kind else { return err(l.pat.span, "a frame goes in one variable") };
        if l.ty.is_some() || l.is_static || l.comptime {
            return err(l.span, "a frame's type comes from its fn: val fr = async f()");
        }
        if !matches!(call.kind, ExprKind::Call(..)) {
            return err(call.span, "async needs a call to an async fn");
        }
        let v = self.marked_call(call, None, true)?;
        let Ty::Frame(i) = self.t.get(v.ty).clone() else { return err(call.span, "async needs a direct call to one async fn") };
        let fc = self.cty(v.ty);
        let (c, flag) = self.owned_local(name, v.ty, l.mutable)?;
        let x = self.fns[i as usize].c_name.clone();
        Ok((format!("{};{flag} {x}_step(&{c});", Self::decl(&fc, &c, &v.c)), false))
    }

    pub fn frame_cty(&mut self, inst: usize) -> String {
        let t = self.t.intern(Ty::Frame(inst as u32));
        self.cty(t)
    }

    /// prototypes of the step/await/run functions next to the frame-building one
    pub fn async_protos(&mut self, idx: usize) -> String {
        let fc = self.frame_cty(idx);
        let x = self.fns[idx].c_name.clone();
        let rc = if self.fns[idx].ret == VOID { "void".to_string() } else { self.cty(self.fns[idx].ret) };
        format!("static bool {x}_step({fc}* _f);\nstatic {rc} {x}_await({fc}* p);\nstatic {rc} {x}_run({fc} f);\n")
    }

    /// emit an async fn: frame builder, step function, await and run helpers
    pub fn gen_async(&mut self, idx: usize, code: String, param_cs: &[String]) -> Res<()> {
        self.check_suspends(&code)?;
        let inst = self.fns[idx].clone();
        let fc = self.frame_cty(idx);
        let x = &inst.c_name;
        // step: jump back to the suspend point the frame stopped at (state 0 = from the start)
        let cases: String = (1..=self.cx.suspends.len()).map(|n| format!("case {n}: goto volt_s{n}; ")).collect();
        self.bodies.push_str(&format!("static bool {x}_step({fc}* _f) {{\nswitch (_f->state) {{ case 0: break; {cases}default: return true; }}\n{code}\n}}\n"));
        // the builder (the fn itself): a zeroed frame holding the arguments
        let sets: String = inst
            .params
            .iter()
            .enumerate()
            .filter(|(_, p)| !p.comptime)
            .zip(param_cs)
            .map(|((i, p), c)| format!("f.{} = {}_{i}; ", &c["_f->".len()..], p.name))
            .collect();
        let header = self.fn_header(idx, true);
        self.bodies.push_str(&format!("{header} {{ {fc} f = {{0}}; {sets}return f; }}\n"));
        // await: panics on a second await, steps until done, then takes the result; run: awaits a frame
        // of its own
        let (rc, give) = if inst.ret == VOID { ("void".to_string(), "") } else { (self.cty(inst.ret), "return p->ret; ") };
        let loc = self.loc(self.decls[inst.decl].item.span);
        self.bodies.push_str(&format!(
            "static {rc} {x}_await({fc}* p) {{ if (p->state == VOLT_TAKEN) volt_panic(\"awaited a frame that was already awaited\", \"{loc}\"); while (p->state < VOLT_DONE) {x}_step(p); p->state = VOLT_TAKEN; {give}}}\n"
        ));
        let ret_kw = if inst.ret == VOID { "" } else { "return " };
        self.bodies.push_str(&format!("static {rc} {x}_run({fc} f) {{ {ret_kw}{x}_await(&f); }}\n\n"));
        Ok(())
    }

    /// C can't jump into a statement expression `({ ... })`, so no resume label may sit in one
    /// (it scans the C for a `volt_s<n>:` label while some enclosing brace opens a `({`)
    fn check_suspends(&self, code: &str) -> Res<()> {
        let b = code.as_bytes();
        let mut braces: Vec<bool> = Vec::new(); // per open brace: does it start a ({ ... })
        let mut i = 0;
        while i < b.len() {
            match b[i] {
                q @ (b'"' | b'\'') => {
                    i += 1;
                    while i < b.len() && b[i] != q {
                        i += if b[i] == b'\\' { 2 } else { 1 };
                    }
                }
                b'{' => braces.push(i > 0 && b[i - 1] == b'('),
                b'}' => {
                    braces.pop();
                }
                b'v' if braces.contains(&true) && code[i..].starts_with("volt_s") && (i == 0 || !(b[i - 1] as char).is_ascii_alphanumeric() && b[i - 1] != b'_') => {
                    let digits: String = code[i + 6..].chars().take_while(|c| c.is_ascii_digit()).collect();
                    if !digits.is_empty() && code[i + 6 + digits.len()..].starts_with(":;") {
                        let n: usize = digits.parse().unwrap();
                        return err(self.cx.suspends[n - 1], "suspend can't go inside something that gives a value (a match, loop or block used as a value)");
                    }
                }
                _ => {}
            }
            i += 1;
        }
        Ok(())
    }

    /// an async fn that starts itself with `async` would have a frame containing itself
    pub fn check_frame_cycles(&self) -> Res<()> {
        let mut starts: Vec<usize> = self.frames.keys().copied().collect();
        starts.sort();
        for start in starts {
            let (mut stack, mut seen) = (vec![start], HashSet::new());
            while let Some(i) = stack.pop() {
                for (_, t) in &self.frames[&i] {
                    if let Ty::Frame(j) = self.t.get(*t) {
                        let j = *j as usize;
                        if j == start {
                            let name = &self.fns[start].name;
                            return err(self.decls[self.fns[start].decl].item.span, format!("'{name}' starts itself with async, so its frame would contain itself; call or await it instead"));
                        }
                        if seen.insert(j) && self.frames.contains_key(&j) {
                            stack.push(j);
                        }
                    }
                }
            }
        }
        Ok(())
    }
}
