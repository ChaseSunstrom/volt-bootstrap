// Statements and control flow: blocks and scopes, locals, if/while/for/loop, break/continue with
// labels, return, defer/errdefer, and the scope-end deletes that ownership asks for.
use super::*;

impl Checker {
    /// declare a local in the innermost scope and return its C name (a frame field in an async fn: slot)
    pub fn new_local(&mut self, name: &str, ty: TyId, mutable: bool) -> String {
        let c = self.slot(name, ty);
        self.cx.scopes.last_mut().unwrap().vars.insert(name.to_string(), Local { c: c.clone(), ty, mutable, orig: None, flag: None, loops: self.cx.loops.iter().filter(|l| !l.is_block).count() });
        c
    }

    /// `{ ... }` with its own scope. Returns C code and whether it always diverges.
    pub fn block_code(&mut self, b: &Block) -> Res<(String, bool)> {
        self.cx.scopes.push(Scope::default());
        let r = self.block_inner(b);
        let scope = self.cx.scopes.len() - 1;
        let r = r.and_then(|(mut code, div)| {
            if !div {
                code.push_str(&self.scope_exit_code(scope, scope, false)?);
            }
            Ok((format!("{{\n{code}}}"), div))
        });
        self.cx.scopes.pop();
        r
    }

    fn block_inner(&mut self, b: &Block) -> Res<(String, bool)> {
        let mut code = String::new();
        let mut div = false;
        for s in &b.stmts {
            let (c, d) = self.stmt(s)?;
            if !c.is_empty() {
                code.push_str(&c);
                code.push('\n');
            }
            div |= d;
        }
        Ok((code, div))
    }

    /// one statement: its C code and whether it always diverges; defer/errdefer only register an exit
    fn stmt(&mut self, s: &Stmt) -> Res<(String, bool)> {
        match &s.kind {
            StmtKind::Let(l) => {
                // temporaries in the initializer live as long as the variable: to the end of this scope
                let scope = self.cx.scopes.len() - 1;
                let ((code, div), decls, _) = self.keeping(scope, |c| c.let_stmt(l))?;
                Ok((format!("{decls}{code}"), div))
            }
            StmtKind::Expr(e) if matches!(e.kind, ExprKind::Break(_, Some(_))) && self.cx.keep_temps.is_some() => {
                // a break's value leaves its block: its temporaries belong to the statement the block
                // is part of (`val x = :b { break :b f().as_str(); }` keeps them as long as x)
                let v = self.expr(e, None)?;
                let never = v.ty == NEVER;
                Ok((format!("{};", self.discard(v)?), never))
            }
            StmtKind::Expr(e) => {
                // temporaries live to the end of the statement: a scope of its own deletes them on an
                // early exit, and the code after the statement on the way out
                self.cx.scopes.push(Scope::default());
                let scope = self.cx.scopes.len() - 1;
                let r = self.keeping(scope, |c| {
                    let v = c.expr(e, None)?;
                    let never = v.ty == NEVER;
                    Ok((format!("{};", c.discard(v)?), never))
                });
                self.cx.scopes.pop();
                let ((code, never), decls, drops) = r?;
                Ok((format!("{decls}{code} {drops}"), never))
            }
            StmtKind::Defer(e) | StmtKind::ErrDefer(e) => {
                let is_err = matches!(s.kind, StmtKind::ErrDefer(_));
                self.cx.scopes.last_mut().unwrap().exits.push(Exit::Defer(e.clone(), is_err));
                Ok((String::new(), false))
            }
            StmtKind::Suspend => Ok((self.suspend(s.span)?, false)),
            StmtKind::Resume(e) => Ok((self.resume(e, s.span)?, false)),
        }
    }

    /// run f keeping the receiver temporaries it makes (see keep_temps), their exits in scope `scope`:
    /// f's result, the temporaries' declarations, and the code that deletes the live ones
    fn keeping<T>(&mut self, scope: usize, f: impl FnOnce(&mut Self) -> Res<T>) -> Res<(T, String, String)> {
        let outer = self.cx.keep_temps.replace(Vec::new());
        let outer_scope = std::mem::replace(&mut self.cx.keep_scope, scope);
        let r = f(self);
        let kept = std::mem::replace(&mut self.cx.keep_temps, outer).unwrap_or_default();
        self.cx.keep_scope = outer_scope;
        let r = r?;
        let (mut decls, mut drops) = (String::new(), String::new());
        for (t, ty, flag) in kept {
            // an async fn's are frame fields, declared with the frame
            if !t.starts_with("_f->") {
                decls.push_str(&format!("{} {t}; ", self.cty(ty)));
            }
            decls.push_str(&format!("{}; ", Self::decl("bool", &flag, "false")));
            if self.needs_drop(ty)? {
                drops.push_str(&format!("if ({flag}) {}(&{t}); ", self.drop_fn(ty)?));
            }
        }
        Ok((r, decls, drops))
    }

    /// Type for a declaration, filling in `T[]` lengths from the initializer.
    pub fn decl_type(&mut self, t: &Type, init: Option<&Expr>) -> Res<TyId> {
        let env = self.cx.env.clone();
        if let TypeKind::Array(inner, None) = &t.kind {
            let elem = self.resolve_type(inner, &env)?;
            let n = match init.map(|e| &e.kind) {
                Some(ExprKind::Literal(entries)) => entries.len() as i128,
                Some(ExprKind::Range(Some(lo), Some(hi), incl)) => self.const_int(hi, &env)? - self.const_int(lo, &env)? + *incl as i128,
                Some(_) => {
                    let v = self.expr(init.unwrap(), None)?;
                    match self.t.get(v.ty) {
                        Ty::Array(_, n) => *n as i128,
                        _ => return err(t.span, "T[] needs an initializer with a known length"),
                    }
                }
                None => return err(t.span, "T[] takes its length from an initializer"),
            };
            let n = array_len(n, t.span)?;
            return Ok(self.t.intern(Ty::Array(elem, n)));
        }
        self.resolve_type(t, &env)
    }

    /// `var`/`val`: check the initializer against the declared type (or take its type), then bind a
    /// name or destructure a tuple. The value moves in.
    fn let_stmt(&mut self, l: &Let) -> Res<(String, bool)> {
        if let Some(Expr { kind: ExprKind::Async(call), .. }) = &l.init {
            return self.async_let(l, call);
        }
        if l.comptime {
            self.ct_let(l)?;
            return Ok((String::new(), false));
        }
        let decl_ty = match &l.ty {
            Some(t) => Some(self.decl_type(t, l.init.as_ref())?),
            None => None,
        };
        let v = match (&l.init, decl_ty) {
            (Some(init), Some(t)) => {
                let v = self.expr(init, Some(t))?;
                self.take_into(v, t, init.span)?
            }
            (Some(init), None) => {
                let v = self.expr(init, None)?;
                match v.ty {
                    NULL => return err(init.span, "can't tell the type of null here; add a type: var x: T? = null"),
                    VOID => return err(init.span, "this has no value"),
                    _ => self.take(v, init.span)?,
                }
            }
            (None, Some(t)) => self.zero_value(t, l.span)?,
            (None, None) => return err(l.span, "a variable needs a type or an initializer"),
        };
        if v.ty == NEVER {
            return Ok((format!("{};", v.c), true));
        }
        let ty = v.ty;
        let cty = self.cty(ty);
        let storage = if l.is_static { "static " } else { "" };
        match &l.pat.kind {
            PatKind::Bind(name) => {
                if l.is_static {
                    let frame = self.cx.frame.take(); // a C static, shared by every frame
                    let c = self.new_local(name, ty, l.mutable);
                    self.cx.frame = frame;
                    return Ok((format!("{storage}{cty} {c} = {};", v.c), false));
                }
                let (c, flag) = self.owned_local(name, ty, l.mutable)?;
                Ok((format!("{};{flag}", Self::decl(&cty, &c, &v.c)), false))
            }
            PatKind::Tuple(pats) => {
                let Ty::Tuple(ts, _) = self.t.get(ty).clone() else {
                    return err(l.pat.span, format!("can't destructure a {}", self.ty_name(ty)));
                };
                if ts.len() != pats.len() {
                    return err(l.pat.span, format!("expected {} names, the tuple has {}", pats.len(), ts.len()));
                }
                let tmp = self.tmp("t");
                let mut code = format!("{cty} {tmp} = {};", v.c);
                for (i, (p, t)) in pats.iter().zip(ts).enumerate() {
                    let PatKind::Bind(name) = &p.kind else { return err(p.span, "expected a name") };
                    let ec = self.cty(t);
                    let (c, flag) = self.owned_local(name, t, l.mutable)?;
                    code.push_str(&format!(" {};{flag}", Self::decl(&ec, &c, &format!("{tmp}.f{i}"))));
                }
                Ok((code, false))
            }
            _ => err(l.pat.span, "expected a name or (a, b)"),
        }
    }

    /// value of `var x: T;` with no initializer
    pub fn zero_value(&mut self, t: TyId, span: Span) -> Res<Val> {
        match self.t.get(t).clone() {
            Ty::Struct(sid) if self.header_struct(sid) => {
                let c = self.cty(t);
                Ok(Val::pure(t, format!("(({c}){{0}})")))
            }
            Ty::Struct(sid) => {
                let fields = self.struct_fields(sid, span)?;
                let mut inits = Vec::new();
                for f in fields.iter() {
                    let v = if f.default.is_some() || matches!(self.t.get(f.ty), Ty::Opt(_)) {
                        self.field_default(sid, f, span)?
                    } else if matches!(self.t.get(f.ty), Ty::Ref(_)) {
                        return err(span, format!("{} needs an initializer: field '{}' is a reference and can't default", self.ty_name(t), f.name));
                    } else {
                        self.zero_value(f.ty, span)?
                    };
                    if f.ty != VOID {
                        inits.push(format!(".{} = {}", c_field(&f.name), v.c));
                    }
                }
                let c = self.cty(t);
                Ok(Val::pure(t, format!("(({c}){{ {} }})", inits.join(", "))))
            }
            Ty::Ref(_) => err(span, format!("a {} needs an initializer (references can't be null)", self.ty_name(t))),
            Ty::Opt(_) => Ok(self.none(t)),
            _ => {
                let c = self.cty(t);
                Ok(Val::pure(t, format!("(({c}){{0}})")))
            }
        }
    }

    // ---------- exits ----------

    /// deferred code for scopes [to, from] (innermost first), each checked in its own scope
    pub fn scope_exit_code(&mut self, from: usize, to: usize, is_err: bool) -> Res<String> {
        self.cx.no_suspend += 1;
        // the exits' own statements keep their temporaries (each defer has a context of its own)
        let keep = self.cx.keep_temps.take();
        let r = self.scope_exit_inner(from, to, is_err);
        self.cx.keep_temps = keep;
        self.cx.no_suspend -= 1;
        r
    }

    fn scope_exit_inner(&mut self, from: usize, to: usize, is_err: bool) -> Res<String> {
        let mut code = String::new();
        for i in (to..=from).rev() {
            let exits = self.cx.scopes[i].exits.clone();
            if exits.is_empty() {
                continue;
            }
            // a scope's defers see only the scopes up to their own
            let hidden = self.cx.scopes.split_off(i + 1);
            let r = (|| {
                for ex in exits.iter().rev() {
                    match ex {
                        Exit::Defer(e, only_err) => {
                            if *only_err && !is_err {
                                continue;
                            }
                            // a deferred statement's temporaries live to its end, like any statement's
                            self.cx.scopes.push(Scope::default());
                            let s = self.cx.scopes.len() - 1;
                            let r = self.keeping(s, |c| c.expr(e, None));
                            self.cx.scopes.pop();
                            let (v, decls, drops) = r?;
                            code.push_str(&format!("{decls}{}; {drops}\n", v.c));
                        }
                        Exit::Drop { c, drop, flag } => code.push_str(&format!("if ({flag}) {drop}(&{c});\n")),
                    }
                }
                Ok(())
            })();
            self.cx.scopes.extend(hidden);
            r?;
        }
        Ok(code)
    }

    /// `return`: the value moves out, then every scope's exits run (errdefers too when an error union
    /// return value holds an error)
    pub fn ret(&mut self, v: Option<&Expr>, span: Span) -> Res<Val> {
        let ret = self.cx.ret;
        let is_eu = matches!(self.t.get(ret), Ty::ErrUnion(..));
        let val = match v {
            Some(e) => {
                self.cx.exiting += 1;
                let r = self.expr(e, Some(ret)).and_then(|v| self.take_into(v, ret, e.span));
                self.cx.exiting -= 1;
                Some(r?)
            }
            None if ret == VOID => None,
            None if matches!(self.t.get(ret), Ty::ErrUnion(_, VOID)) => {
                let rc = self.cty(ret);
                Some(Val::pure(ret, format!("(({rc}){{0}})")))
            }
            None => return err(span, format!("return needs a {} value", self.ty_name(ret))),
        };
        let top = self.cx.scopes.len() - 1;
        let mut defers = self.scope_exit_code(top, 0, false)?;
        if is_eu {
            let err_defers = self.scope_exit_code(top, 0, true)?;
            if err_defers != defers {
                let code = self.eu_code(ret, self.ret_slot());
                defers = format!("if ({code}) {{ {err_defers} }} else {{ {defers} }} ");
            }
        }
        let code = match val {
            Some(v) if v.ty == NEVER => v.c,
            v => self.fn_exit(v.map(|v| v.c), &defers),
        };
        Ok(Val::new(NEVER, code))
    }

    /// the loop a break/continue targets: the one with the label, else the innermost loop (a block
    /// only by label)
    fn find_loop(&self, label: Option<&str>, for_continue: bool, span: Span) -> Res<usize> {
        for (i, l) in self.cx.loops.iter().enumerate().rev() {
            let hit = match label {
                Some(name) => l.label.as_deref() == Some(name),
                None => !l.is_block,
            };
            if hit {
                if for_continue && l.is_block {
                    return err(span, "continue needs a loop, not a block");
                }
                return Ok(i);
            }
        }
        match label {
            Some(n) => err(span, format!("no loop or block labeled :{n} around here")),
            None => err(span, "break/continue outside of a loop"),
        }
    }

    /// `break` (with a value, for a loop or labeled block): run the exits of the scopes it leaves, then
    /// jump out
    pub fn brk(&mut self, label: Option<&str>, v: Option<&Expr>, span: Span) -> Res<Val> {
        let li = self.find_loop(label, false, span)?;
        let mut assign = String::new();
        if let Some(e) = v {
            if self.cx.loops[li].result.is_none() {
                return err(e.span, "only loop and labeled blocks can break with a value");
            }
            self.cx.exiting += 1;
            let got = self.expr(e, self.cx.loops[li].break_ty).and_then(|v| self.take(v, e.span));
            self.cx.exiting -= 1;
            let got = got?;
            let val = match self.cx.loops[li].break_ty {
                Some(t) => self.coerce(got, t, e.span)?,
                None => {
                    let v = got;
                    if v.ty == VOID || v.ty == NULL {
                        return err(e.span, "break needs a value with a type here");
                    }
                    self.cx.loops[li].break_ty = Some(v.ty);
                    v
                }
            };
            assign = format!("{} = {}; ", self.cx.loops[li].result.clone().unwrap(), val.c);
        } else if self.cx.loops[li].break_ty.is_some() && self.cx.loops[li].result.is_some() {
            return err(span, "this loop breaks with a value elsewhere, so this break needs one too");
        }
        self.cx.loops[li].has_break = true;
        let moved = self.cx.moved.clone();
        self.cx.loops[li].moved_at_break.extend(moved);
        let top = self.cx.scopes.len() - 1;
        let depth = self.cx.loops[li].depth;
        let defers = self.scope_exit_code(top, depth, false)?;
        Ok(Val::new(NEVER, format!("{{ {assign}{defers}goto {}; }}", self.cx.loops[li].brk)))
    }

    /// `continue`: run the exits of the scopes it leaves, then jump to the loop's next round
    pub fn cont(&mut self, label: Option<&str>, span: Span) -> Res<Val> {
        let li = self.find_loop(label, true, span)?;
        let top = self.cx.scopes.len() - 1;
        let depth = self.cx.loops[li].depth;
        let defers = if top >= depth { self.scope_exit_code(top, depth, false)? } else { String::new() };
        Ok(Val::new(NEVER, format!("{{ {defers}goto {}; }}", self.cx.loops[li].cont.clone().unwrap())))
    }

    // ---------- control flow ----------

    /// start a loop or labeled block: its labels, and a result variable when it can break with a value
    fn push_loop(&mut self, label: Option<&str>, is_block: bool, value: bool, want: Option<TyId>) -> usize {
        let id = self.tmp("");
        let lc = LoopCx {
            label: label.map(String::from),
            is_block,
            brk: format!("brk{id}"),
            cont: if is_block { None } else { Some(format!("cont{id}")) },
            result: if value { Some(format!("lr{id}")) } else { None },
            break_ty: if value { want } else { None },
            has_break: false,
            depth: self.cx.scopes.len(),
            moved_at_break: Default::default(),
        };
        self.cx.loops.push(lc);
        self.cx.loops.len() - 1
    }

    /// wrap finished loop code as a value (break with value) or a statement
    fn finish_loop(&mut self, code: String, body_div: bool, span: Span, value_needs_break: bool) -> Res<Val> {
        let lc = self.cx.loops.pop().unwrap();
        // what was moved on the way to a break is moved after the loop too
        self.cx.moved.extend(lc.moved_at_break.iter().cloned());
        let brk = format!("{}:;", lc.brk);
        if let (Some(r), Some(t)) = (&lc.result, lc.break_ty) {
            if lc.has_break {
                if value_needs_break && !body_div {
                    return err(span, "this block needs to end with a break that gives its value");
                }
                let c = self.cty(t);
                return Ok(Val::new(t, format!("({{ {c} {r}; {code} {brk} {r}; }})")));
            }
        }
        let ty = if body_div && !lc.has_break { NEVER } else { VOID };
        Ok(Val::new(ty, format!("{{ {code} {brk} }}")))
    }

    /// `{ ... }`, or a labeled block that break can leave with a value
    pub fn block_expr(&mut self, label: Option<&str>, b: &Block, want: Option<TyId>, span: Span) -> Res<Val> {
        let Some(label) = label else {
            let (code, div) = self.block_code(b)?;
            return Ok(Val::new(if div { NEVER } else { VOID }, code));
        };
        self.push_loop(Some(label), true, true, want);
        let r = self.block_code(b);
        match r {
            Ok((code, div)) => self.finish_loop(code, div, span, true),
            Err(e) => {
                self.cx.loops.pop();
                Err(e)
            }
        }
    }

    /// `loop { ... }`: its value is what a break gives; never, if nothing breaks out
    pub fn loop_expr(&mut self, label: Option<&str>, b: &Block, want: Option<TyId>, span: Span) -> Res<Val> {
        let li = self.push_loop(label, false, true, want);
        let cont = self.cx.loops[li].cont.clone().unwrap();
        match self.block_code(b) {
            Ok((body, _)) => self.finish_loop(format!("for (;;) {{ {body} {cont}:; }}"), true, span, false),
            Err(e) => {
                self.cx.loops.pop();
                Err(e)
            }
        }
    }

    /// `while (cond) { ... }`; the condition may narrow an optional or pointer inside the body
    pub fn while_expr(&mut self, label: Option<&str>, cond: &Expr, b: &Block, span: Span) -> Res<Val> {
        let li = self.push_loop(label, false, false, None);
        let cont = self.cx.loops[li].cont.clone().unwrap();
        let r = (|| {
            let mark = self.cx.keep_temps.as_ref().map(|k| k.len());
            let (test, narrow) = self.cond(cond)?;
            // the condition runs once per round: its temporaries are deleted after each test
            let mut drops = String::new();
            let made = match mark {
                Some(m) => self.cx.keep_temps.as_ref().unwrap()[m..].to_vec(),
                None => Vec::new(),
            };
            for (t, ty, flag) in made {
                if self.needs_drop(ty)? {
                    drops.push_str(&format!("if ({flag}) {{ {}(&{t}); {flag} = false; }} ", self.drop_fn(ty)?));
                }
            }
            let test = if drops.is_empty() {
                format!("if (!({test})) break;")
            } else {
                let w = self.tmp("wc");
                format!("bool {w} = ({test}); {drops}if (!{w}) break;")
            };
            let (body, _) = self.narrowed(narrow, |c| c.block_code(b))?;
            Ok(format!("for (;;) {{ {test} {body} {cont}:; }}"))
        })();
        match r {
            Ok(code) => self.finish_loop(code, false, span, false),
            Err(e) => {
                self.cx.loops.pop();
                Err(e)
            }
        }
    }

    /// if/else (a statement); the condition may narrow an optional or pointer in the then branch
    pub fn if_expr(&mut self, cond: &Expr, then: &Block, els: Option<&Expr>, _span: Span) -> Res<Val> {
        let (test, narrow) = self.cond(cond)?;
        // moves are tracked per path: a branch that leaves (return, break...) doesn't reach the code
        // after the if, so its moves don't count there (a break's count after its loop)
        let before = self.cx.moved.clone();
        let (tc, tdiv) = self.narrowed(narrow, |c| c.block_code(then))?;
        let after_then = if tdiv { before.clone() } else { std::mem::replace(&mut self.cx.moved, before.clone()) };
        self.cx.moved = before.clone();
        let (ec, ediv) = match els {
            Some(e) => {
                let v = self.expr(e, None)?;
                (format!(" else {}", v.c), v.ty == NEVER)
            }
            None => (String::new(), false),
        };
        if ediv {
            self.cx.moved = before;
        }
        self.cx.moved.extend(after_then);
        Ok(Val::new(if tdiv && ediv { NEVER } else { VOID }, format!("if ({test}) {tc}{ec}")))
    }

    /// run f with a narrowed local (from cond), if any, in a scope of its own
    fn narrowed<T>(&mut self, narrow: Option<(String, Local)>, f: impl FnOnce(&mut Self) -> Res<T>) -> Res<T> {
        let Some((name, local)) = narrow else { return f(self) };
        let mut scope = Scope::default();
        scope.vars.insert(name, local);
        self.cx.scopes.push(scope);
        let r = f(self);
        self.cx.scopes.pop();
        r
    }

    /// `for (x)`, `for (x, i)`, `for (x&)` over a range, array, slice, str or range value; a comptime
    /// for is unrolled
    pub fn for_expr(&mut self, f: &ForLoop, want: Option<TyId>, span: Span) -> Res<Val> {
        if f.comptime {
            return self.ct_for_unroll(f, span);
        }
        if f.bindings.is_empty() || f.bindings.len() > 2 {
            return err(span, "for takes one or two names: for (value) or for (value, index)");
        }
        self.cx.scopes.push(Scope::default());
        let r = self.for_inner(f, want, span);
        self.cx.scopes.pop();
        r
    }

    /// A runtime for loop, in a scope of its own. An accumulator (`[var acc = init]`) is declared
    /// first and is the loop's value; the loop state lives in slots, so an async body can suspend.
    fn for_inner(&mut self, f: &ForLoop, _want: Option<TyId>, span: Span) -> Res<Val> {
        let mut pre = String::new();
        // the iterable's temporaries: declared around the loop, deleted once it's done
        let (mut kept_decls, mut after) = (String::new(), String::new());
        let mut acc_decl = String::new();
        let acc = match &f.acc {
            Some(a) => {
                let (code, _) = self.let_stmt(a)?;
                acc_decl = code;
                let PatKind::Bind(n) = &a.pat.kind else { unreachable!() };
                Some(self.lookup_local(n).unwrap())
            }
            None => None,
        };
        // the iterable
        let (elem_ty, head, elem, index, addressable) = match &f.iter.kind {
            ExprKind::Range(Some(lo), Some(hi), incl) => {
                let a = self.expr(lo, None)?;
                let b = self.expr(hi, Some(a.ty))?;
                let (a, b) = if a.lit.is_some() && b.lit.is_none() {
                    let t = b.ty;
                    (self.coerce(a, t, lo.span)?, b)
                } else {
                    let t = a.ty;
                    (a, self.coerce(b, t, hi.span)?)
                };
                let Some(_) = self.t.int_of(a.ty) else { return err(f.iter.span, "ranges need integers") };
                let t = self.cty(a.ty);
                // loop state lives in slots: in an async fn it must survive a suspend in the body
                let (lo_v, hi_v, it) = (self.slot("_lo", a.ty), self.slot("_hi", a.ty), self.slot("_it", a.ty));
                pre.push_str(&format!("{}; {};", Self::decl(&t, &lo_v, &a.c), Self::decl(&t, &hi_v, &b.c)));
                let last = if *incl { hi_v.clone() } else { format!("{hi_v} - 1") };
                let cmp = if *incl { "<=" } else { "<" };
                let head = format!("if ({lo_v} {cmp} {hi_v}) for ({};; {it}++) {{", Self::decl(&t, &it, &lo_v));
                let tail = format!("if ({it} == {last}) break;");
                (a.ty, (head, tail), it.clone(), format!("(size_t)({it} - {lo_v})"), false)
            }
            _ => {
                // temporaries the iterable makes (the vec in `f().items()`) live until the loop ends
                let scope = self.cx.scopes.len() - 1;
                let (v, decls, drops) = self.keeping(scope, |c| c.expr(&f.iter, None))?;
                kept_decls = decls;
                after = drops;
                if !v.lv && self.needs_drop(v.ty)? {
                    return err(f.iter.span, "store this in a variable before looping over it (its elements own memory)");
                }
                let mut k = self.slot("_k", USIZE);
                // an iterator: the loop head and the element
                let mut iter_head: Option<(String, String)> = None;
                let (ty, base_ty) = match self.t.get(v.ty).clone() {
                    Ty::Ref(inner) => (inner, Some(v.ty)),
                    _ => (v.ty, None),
                };
                let (elem_ty, len, access) = match self.t.get(ty).clone() {
                    Ty::Array(t, n) => {
                        let pt = self.t.intern(Ty::Ref(ty));
                        let p = self.slot("_a", pt);
                        let at = self.cty(ty);
                        let addr = if base_ty.is_some() {
                            v.c.clone()
                        } else if v.lv {
                            format!("&({})", v.c)
                        } else {
                            let tmpv = self.slot("_av", ty);
                            pre.push_str(&format!("{};", Self::decl(&at, &tmpv, &v.c)));
                            format!("&{tmpv}")
                        };
                        pre.push_str(&format!("{};", Self::decl(&format!("{at}*"), &p, &addr)));
                        (t, n.to_string(), format!("{p}->a[{k}]"))
                    }
                    Ty::Slice(t) => {
                        let s = self.slot("_sl", ty);
                        let st = self.cty(ty);
                        let val = if base_ty.is_some() { format!("*({})", v.c) } else { v.c.clone() };
                        pre.push_str(&format!("{};", Self::decl(&st, &s, &val)));
                        (t, format!("{s}.len"), format!("{s}.ptr[{k}]"))
                    }
                    Ty::Str => {
                        if f.bindings[0].1 {
                            return err(f.bindings[0].2, "a str is read-only, so (x&) can't point into it; loop over it by value instead");
                        }
                        let s = self.slot("_sl", STR);
                        pre.push_str(&format!("{};", Self::decl("volt_str", &s, &v.c)));
                        (U8, format!("{s}.len"), format!("((uint8_t*){s}.ptr)[{k}]"))
                    }
                    Ty::Range(t) => {
                        let r = self.slot("_r", ty);
                        let rt = self.cty(ty);
                        pre.push_str(&format!("{};", Self::decl(&rt, &r, &v.c)));
                        let tc = self.cty(t);
                        k = self.slot("_k", t);
                        let head = format!("for ({}; {k} < {r}.hi; {k}++) {{", Self::decl(&tc, &k, &format!("{r}.lo")));
                        let idx = format!("(size_t)({k} - {r}.lo)");
                        (t, "".into(), format!("{head}|{idx}"))
                    }
                    _ => {
                        // a type that attaches next(this: T&) -> X? (or -> X*) is an iterator: next until
                        // it's null. A pointer binds as an X&
                        let Some(h) = self.hook(ty, "next")? else {
                            let n = self.ty_name(ty);
                            return err(f.iter.span, format!("can't loop over a {} (a type loops when it attaches next(this: {n}&) -> T? or -> T*)", self.ty_name(v.ty)));
                        };
                        self.use_fn(h);
                        let ot = self.fns[h].ret;
                        let pt = self.t.intern(Ty::Ref(ty));
                        let p = self.slot("_ip", pt);
                        // a var (or a reference to one) is advanced in place; a val or a temporary is copied
                        let addr = if base_ty.is_some() {
                            v.c.clone()
                        } else if v.lv && v.mutable {
                            format!("&({})", v.c)
                        } else {
                            let tv = self.slot("_iv", ty);
                            pre.push_str(&format!("{};", Self::decl(&self.cty(ty), &tv, &v.c)));
                            format!("&{tv}")
                        };
                        pre.push_str(&format!("{};", Self::decl(&format!("{}*", self.cty(ty)), &p, &addr)));
                        let nx = self.slot("_nx", ot);
                        // (T){0}: in an async fn the slot is a frame field, assigned rather than declared
                        let otc = self.cty(ot);
                        pre.push_str(&format!("{};", Self::decl(&otc, &nx, &format!("({otc}){{0}}"))));
                        let (has, val, x) = match self.t.get(ot).clone() {
                            Ty::Ptr(t) => (format!("({nx} != 0)"), nx.clone(), self.t.intern(Ty::Ref(t))),
                            Ty::Opt(x) => {
                                let (has, val) = self.opt_parts(ot, &nx);
                                (has, val, x)
                            }
                            _ => unreachable!(),
                        };
                        let head = format!("for ({};; {k}++) {{ {nx} = {}({p}); if (!{has}) break; ", Self::decl("size_t", &k, "0"), self.fns[h].c_name);
                        iter_head = Some((head, val));
                        (x, String::new(), String::new())
                    }
                };
                if let Some((head, val)) = iter_head {
                    (elem_ty, (head, String::new()), val, k.clone(), false)
                } else if len.is_empty() {
                    // range value: access holds "head|index"
                    let (head, idx) = access.split_once('|').unwrap();
                    (elem_ty, (head.to_string(), String::new()), k.clone(), idx.to_string(), false)
                } else {
                    let head = format!("for ({}; {k} < {len}; {k}++) {{", Self::decl("size_t", &k, "0"));
                    (elem_ty, (head, String::new()), access, k.clone(), true)
                }
            }
        };
        // one round: the bindings, `=> map`, the body, the continue label, then the range's last-round check
        let li = self.push_loop(f.label.as_deref(), false, false, None);
        let cont = self.cx.loops[li].cont.clone().unwrap();
        let r = (|| {
            self.cx.scopes.push(Scope::default());
            let r = (|| {
                let mut binds = String::new();
                let (name, by_ref, bspan) = &f.bindings[0];
                let et = self.cty(elem_ty);
                if *by_ref {
                    if !addressable {
                        return err(*bspan, "(x&) needs something stored to point at, like an array or slice");
                    }
                    let rt = self.t.intern(Ty::Ref(elem_ty));
                    let c = self.new_local(name, rt, false);
                    binds.push_str(&format!("{};", Self::decl(&format!("{et}*"), &c, &format!("&{elem}"))));
                } else {
                    let c = self.new_local(name, elem_ty, false);
                    binds.push_str(&format!("{};", Self::decl(&et, &c, &elem)));
                }
                if let Some((iname, _, _)) = f.bindings.get(1) {
                    let c = self.new_local(iname, USIZE, false);
                    binds.push_str(&format!(" {};", Self::decl("size_t", &c, &index)));
                }
                if let Some(m) = &f.map {
                    let v = self.expr(m, None)?;
                    if v.ty == VOID || v.ty == NEVER {
                        return err(m.span, "=> needs a value");
                    }
                    let mt = self.cty(v.ty);
                    let c = self.new_local(name, v.ty, false);
                    binds.push_str(&format!(" {};", Self::decl(&mt, &c, &v.c)));
                }
                let (body, _) = self.block_code(&f.body)?;
                Ok(format!("{} {binds} {body} {cont}:; {} }}", head.0, head.1))
            })();
            self.cx.scopes.pop();
            r
        })();
        let code = match r {
            Ok(c) => c,
            Err(e) => {
                self.cx.loops.pop();
                return Err(e);
            }
        };
        let v = self.finish_loop(format!("{pre} {code}"), false, span, false)?;
        let v = if kept_decls.is_empty() { v } else { Val { c: format!("{{ {kept_decls}{}; {after}}}", v.c), ..v } };
        match acc {
            Some(a) => Ok(Val::new(a.ty, format!("({{ {acc_decl} {}; {}; }})", v.c, a.c))),
            None => Ok(v),
        }
    }
}
