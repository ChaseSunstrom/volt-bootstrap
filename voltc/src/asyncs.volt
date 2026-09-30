// Async fns are stackless state machines, with no scheduler and no heap. A port of
// bootstrap/check/asyncs.rs. `async fn f` becomes a frame (resume state, cancel flag, result, and every
// param/local/loop counter that may live across a suspend) plus `bool f_step(frame&)`, which runs
// to the next suspend (false) or the end (true). `val fr = async f()` builds the frame in place and
// runs it to its first suspend, `resume fr` steps once, `await fr` steps until done and takes the
// result. A plain call (or `await f()`) runs a temporary frame to completion. Frames never move:
// they may point into themselves. Deleting an unfinished frame resumes it in cancel mode, which
// runs its defers and deletes.
use std::mem;

// frame states past the suspend points: finished (result inside), result taken
val VOLT_DONE: i128 = 4294967294;
val VOLT_TAKEN: i128 = 4294967295;

struct async_ir {
    step: u32;  // bool step(frame&)
    wait: u32;  // R await(frame&)
    run: u32;   // R run(frame)
}

fn same_span(a: span, b: span) -> bool {
    return a.file == b.file && a.lo == b.lo && a.hi == b.hi;
}

attach fn is_async_fn(this: checker&, idx: u32) -> bool {
    val f = this.fn_decl_of(this.fi(idx).decl) ?? return false;
    return f.is_async;
}

// the step/await/run functions of an async fn instance, declared on first use
attach fn async_fns(this: checker&, idx: u32) -> async_ir {
    val have = this.async_irs.get(idx);
    if (have) {
        return *have;
    }
    val ft = this.t.intern(tyk::FRAME(idx));
    val fr = this.t.ref_to(ft);
    val ret = this.fi(idx).ret;
    val base = this.fi(idx).c_name;
    val step = this.async_helper(base, "_step", BOOL, "_f", fr);
    val aw = this.async_helper(base, "_await", ret, "p", fr);
    val run = this.async_helper(base, "_run", ret, "f", ft);
    // they belong with the async fn in the C output
    val origin = this.item_of(this.fi(idx).decl).span;
    this.ir.fn_at(step).origin = origin;
    this.ir.fn_at(step).about = this.fi(idx).name;
    this.ir.fn_at(aw).origin = origin;
    this.ir.fn_at(aw).about = this.fi(idx).name;
    this.ir.fn_at(run).origin = origin;
    this.ir.fn_at(run).about = this.fi(idx).name;
    val a: async_ir = { step: step, wait: aw, run: run };
    this.async_irs.put(idx, a);
    return a;
}

// declares helper fn base+suffix(pname: pty) -> ret; gen_async fills in its body
attach fn async_helper(this: checker&, base: str, suffix: str, ret: u32, pname: str, pty: u32) -> u32 {
    var n = S(base);
    n.append(suffix);
    var irf: ir_fn = { name: this.intern(move n), params: {}, ret: ret, link: linkage::STATIC, used: true };
    put(&irf.locals, { name: pname, ty: pty });
    put(&irf.params, 0);
    put(&this.ir.fns, bx(move irf));
    val f = @cast<u32>(this.ir.fns.len - 1);
    put(&this.ir.order, f);
    return f;
}

attach fn async_step_fn(this: checker&, idx: u32) -> u32 {
    return this.async_fns(idx).step;
}

// the frame being stepped (inside an async fn's body)
attach fn frame_obj(this: checker&) -> u32 {
    val ft = this.t.intern(tyk::FRAME(this.cx.frame ?? 0));
    return this.ir.deref(this.cx.frame_ptr, ft);
}

// leave the function with `v` (already of the return type) after running `defers`
attach fn fn_exit(this: checker&, v: u32?, defers: std::vec<u32>, slot: local_ref) -> u32 {
    val ret = this.cx.ret;
    var stmts: std::vec<u32> = {};
    if (this.cx.frame != null) {
        if (v) {
            if (ret == VOID) {
                put(&stmts, v);
            } else {
                put(&stmts, this.ir.assign(slot.c, v));
            }
        }
        for (d&) in defers.items() {
            put(&stmts, *d);
        }
        put(&stmts, this.ir.assign(this.ir.field(this.frame_obj(), 0, U32), this.ir.int(VOLT_DONE, U32)));
        put(&stmts, this.ir.ret(this.ir.boolean(true)));
        return this.ir.block(move stmts);
    }
    if (v == null) {
        stmts = move defers;
        put(&stmts, this.ir.ret(null));
        return this.ir.block(move stmts);
    }
    if (ret == VOID) {
        put(&stmts, v ?? 0);
        for (d&) in defers.items() {
            put(&stmts, *d);
        }
        put(&stmts, this.ir.ret(null));
        return this.ir.block(move stmts);
    }
    if (defers.len == 0) {
        return this.ir.ret(v);
    }
    put(&stmts, this.ir.assign(slot.c, v ?? 0));
    for (d&) in defers.items() {
        put(&stmts, *d);
    }
    put(&stmts, this.ir.ret(slot.c));
    return this.ir.block(move stmts);
}

// where fn_exit keeps the return value while defers run
attach fn ret_slot(this: checker&) -> local_ref {
    val ret = this.cx.ret;
    if (this.cx.frame != null) {
        return { id: 0, c: this.ir.field(this.frame_obj(), 2, ret) };
    }
    if (ret == VOID || ret == NEVER) {
        return { id: 0, c: this.ir.zero(VOID) }; // never read
    }
    if (this.cx.ret_local == null) {
        this.cx.ret_local = this.new_ir_local("_ret", ret);
    }
    return this.cx.ret_local ?? { id: 0, c: 0 };
}

// `suspend;`: records resume point n and returns false from the step fn; the step fn's switch jumps back
// to its label. A frame cancelled while stopped here runs its cleanup and finishes instead
attach fn suspend_code(this: checker&, span: span) -> compile_error!u32 {
    if (this.cx.frame == null) {
        return fails(span, "suspend only works inside an async fn");
    }
    if (this.cx.no_suspend > 0) {
        return fails(span, "suspend can't be inside a defer");
    }
    put(&this.cx.suspends, span);
    val n = this.cx.suspends.len;
    val l = this.ir.label();
    put(&this.cx.suspend_labels, l);
    // cancelled here (deleted before finishing): leave like a return, without a value
    val top = this.cx.scopes.len - 1;
    var cleanup = try this.scope_exit_code(top, 0, false);
    val obj = this.frame_obj();
    val state = this.ir.field(obj, 0, U32);
    put(&cleanup, this.ir.assign(state, this.ir.int(VOLT_TAKEN, U32)));
    put(&cleanup, this.ir.ret(this.ir.boolean(true)));
    var stmts: std::vec<u32> = {};
    put(&stmts, this.ir.assign(state, this.ir.int(@cast<i128>(n), U32)));
    put(&stmts, this.ir.ret(this.ir.boolean(false)));
    put(&stmts, this.ir.label_at(l));
    put(&stmts, this.ir.if_(this.ir.field(obj, 1, BOOL), this.ir.block(move cleanup), null));
    return this.ir.block(move stmts);
}

struct frame_at {
    p: u32;   // a pointer to the frame
    idx: u32; // its fn instance
}

// a pointer to the frame `e` names, and its fn instance
attach fn frame_ptr_of(this: checker&, e: expr&, what: str) -> compile_error!frame_at {
    val v = try this.expr(e, null);
    match (*this.t.get(v.ty)) {
        .FRAME(i) => {
            if (v.lv) {
                return { p: this.ir.addr(v.c, this.t.ref_to(v.ty)), idx: i };
            }
        },
        .REF(t) => {
            match (*this.t.get(t)) {
                .FRAME(i) => { return { p: v.c, idx: i }; },
                default => {},
            }
        },
        .PTR(t) => {
            match (*this.t.get(t)) {
                .FRAME(i) => { return { p: v.c, idx: i }; },
                default => {},
            }
        },
        default => {},
    }
    return fail(e.span, fmt2("{} needs a frame (val fr = async f()), found {}", S(what), this.ty_name(v.ty)));
}

// `resume fr;`: steps the frame once; a frame that already finished panics
attach fn resume_code(this: checker&, e: expr&, span: span) -> compile_error!u32 {
    val f = try this.frame_ptr_of(e, "resume");
    val ft = this.t.intern(tyk::FRAME(f.idx));
    val p = this.tmp_local("p", this.t.ref_to(ft));
    val state = this.ir.field(this.ir.deref(p.c, ft), 0, U32);
    val done = this.ir.binary(binop_ir::GE, state, this.ir.int(VOLT_DONE, U32), BOOL);
    var stmts = nodes(this.ir.decl(p.id, f.p));
    put(&stmts, this.ir.if_(done, this.ir.panic("resumed a frame that already finished", this.loc(span)), null));
    put(&stmts, this.call_fn(this.async_step_fn(f.idx), nodes(p.c), BOOL));
    return this.ir.block(move stmts);
}

// `await fr` steps the frame to its end and takes the result; `await f()` is a checked plain call
attach fn await_expr(this: checker&, e: expr&, want: u32?) -> compile_error!tval {
    match (e.kind) {
        .CALL(c, a) => { return this.marked_call(e, want, false); },
        default => {},
    }
    val f = try this.frame_ptr_of(e, "await");
    val ret = this.fi(f.idx).ret;
    return vnew(ret, this.call_fn(this.async_fns(f.idx).wait, nodes(f.p), ret));
}

// check a call that must reach an async fn: started (a frame) or awaited (its result)
attach fn marked_call(this: checker&, call: expr&, want: u32?, start: bool) -> compile_error!tval {
    // call_mode stays set until async_call claims this call by its span; still set afterwards means the
    // call never reached an async fn
    val saved_mode = this.cx.call_mode;
    val saved_span = this.cx.call_span;
    val saved_start = this.cx.call_start;
    this.cx.call_mode = true;
    this.cx.call_span = call.span;
    this.cx.call_start = start;
    val v = this.expr(call, want);
    val missed = this.cx.call_mode;
    this.cx.call_mode = saved_mode;
    this.cx.call_span = saved_span;
    this.cx.call_start = saved_start;
    val r = try v;
    if (missed) {
        var what = "await";
        if (start) {
            what = "async";
        }
        return fail(call.span, fmt("{} needs a call to an async fn", S(what)));
    }
    return r;
}

// emit_call's hook: how a call to `inst` at `span` is lowered. A call to an async fn runs a temporary
// frame to completion (f_run), unless it's marked `async`: then it gives the frame itself
attach fn async_call(this: checker&, inst: u32, call: u32, span: span) -> compile_error!tval {
    var marked = false;
    var start = false;
    if (this.cx.call_mode && same_span(this.cx.call_span, span)) {
        this.cx.call_mode = false;
        marked = true;
        start = this.cx.call_start;
    }
    val ret = this.fi(inst).ret;
    if (!this.is_async_fn(inst)) {
        if (marked) {
            return fail(span, fmt("'{}' isn't an async fn", S(this.fi(inst).name)));
        }
        return vnew(ret, call);
    }
    val ft = this.t.intern(tyk::FRAME(inst));
    this.ir.at(call).ty = ft; // the fn itself builds the frame
    if (marked && start) {
        return vnew(ft, call);
    }
    return vnew(ret, this.call_fn(this.async_fns(inst).run, nodes(call), ret));
}

// `val fr = async f(args)`: build the frame in place, then run it to its first suspend
attach fn async_let(this: checker&, l: let_stmt&, call: expr&) -> compile_error!code {
    var name: str = "";
    match (l.pat.kind) {
        .BIND(n) => { name = n; },
        default => { return fails(l.pat.span, "a frame goes in one variable"); },
    }
    if (l.ty != null || l.is_static || l.is_comptime) {
        return fails(l.span, "a frame's type comes from its fn: val fr = async f()");
    }
    match (call.kind) {
        .CALL(c, a) => {},
        default => { return fails(call.span, "async needs a call to an async fn"); },
    }
    val v = try this.marked_call(call, null, true);
    var idx: u32 = 0;
    match (*this.t.get(v.ty)) {
        .FRAME(i) => { idx = i; },
        default => { return fails(call.span, "async needs a direct call to one async fn"); },
    }
    val o = try this.owned_local(name, v.ty, l.mutable);
    var stmts = nodes(this.decl_at(o.c, v.c));
    if (o.flag) {
        put(&stmts, o.flag);
    }
    put(&stmts, this.call_fn(this.async_step_fn(idx), nodes(this.ir.addr(o.c, this.t.ref_to(v.ty))), BOOL));
    return { c: this.ir.block(move stmts), div: false };
}

// an async fn's helpers: the frame builder (the fn itself), step, await and run
attach fn gen_async(this: checker&, idx: u32, code: u32, param_cs: std::vec<u32>&) -> compile_error!void {
    try this.check_suspends(code);
    val a = this.async_fns(idx);
    val ft = this.t.intern(tyk::FRAME(idx));
    val ret = this.fi(idx).ret;
    // step: jump back to where it suspended
    val sp = this.ir.node(ir_kind::LOCAL(0), this.t.ref_to(ft));
    val state = this.ir.field(this.ir.deref(sp, ft), 0, U32);
    var cases: std::vec<case_arm> = {};
    put(&cases, { value: 0, body: this.nop() });
    for (i) in 0..this.cx.suspend_labels.len {
        put(&cases, { value: @cast<i128>(i) + 1, body: this.ir.goto_(*this.cx.suspend_labels.at(i)) });
    }
    val sw = this.ir.node(ir_kind::SWITCH(state, move cases, this.ir.ret(this.ir.boolean(true))), VOID);
    this.ir.fn_at(a.step).body = this.ir.block(nodes2(sw, code));
    put(&this.ir.bodies, a.step);
    // the builder: a zeroed frame holding the arguments
    val bf = this.fi(idx).ir;
    val fl = this.ir.fn_at(bf);
    put(&fl.locals, { name: "f", ty: ft });
    val fid = @cast<u32>(fl.locals.len - 1);
    val f = this.ir.node(ir_kind::LOCAL(fid), ft);
    var stmts = nodes(this.ir.decl(fid, this.ir.zero(ft)));
    val pids = copy this.ir.fn_at(bf).params;
    for (k) in 0..pids.len {
        val pid = *pids.at(k);
        val pt = this.ir.fn_at(bf).locals.at(@cast<usize>(pid)).ty;
        match (this.ir.at(*param_cs.at(k)).kind) {
            .FIELD(base, n) => { put(&stmts, this.ir.assign(this.ir.field(f, n, pt), this.ir.node(ir_kind::LOCAL(pid), pt))); },
            default => {},
        }
    }
    put(&stmts, this.ir.ret(f));
    this.ir.fn_at(bf).body = this.ir.block(move stmts);
    put(&this.ir.bodies, bf);
    // await: step until done, then take the result
    val loc = this.loc(this.item_of(this.fi(idx).decl).span);
    val ap = this.ir.node(ir_kind::LOCAL(0), this.t.ref_to(ft));
    val ast = this.ir.field(this.ir.deref(ap, ft), 0, U32);
    val taken = this.ir.binary(binop_ir::EQ, ast, this.ir.int(VOLT_TAKEN, U32), BOOL);
    var aw = nodes(this.ir.if_(taken, this.ir.panic("awaited a frame that was already awaited", loc), null));
    val end = this.ir.label();
    val done = this.ir.binary(binop_ir::GE, ast, this.ir.int(VOLT_DONE, U32), BOOL);
    val lp = this.ir.block(nodes2(this.ir.if_(done, this.ir.goto_(end), null), this.call_fn(a.step, nodes(ap), BOOL)));
    put(&aw, this.ir.node(ir_kind::LOOP(lp), VOID));
    put(&aw, this.ir.label_at(end));
    put(&aw, this.ir.assign(ast, this.ir.int(VOLT_TAKEN, U32)));
    if (ret != VOID) {
        put(&aw, this.ir.ret(this.ir.field(this.ir.deref(ap, ft), 2, ret)));
    }
    this.ir.fn_at(a.wait).body = this.ir.block(move aw);
    put(&this.ir.bodies, a.wait);
    // run: await a frame of its own
    val rf = this.ir.node(ir_kind::LOCAL(0), ft);
    val call = this.call_fn(a.wait, nodes(this.ir.addr(rf, this.t.ref_to(ft))), ret);
    if (ret == VOID) {
        this.ir.fn_at(a.run).body = this.ir.block(nodes(call));
    } else {
        this.ir.fn_at(a.run).body = this.ir.block(nodes(this.ir.ret(call)));
    }
    put(&this.ir.bodies, a.run);
}

// C can't jump into a statement expression, so no resume label may sit in a value-giving SEQ
attach fn check_suspends(this: checker&, n: u32) -> compile_error!void {
    return this.suspends_in(n, false);
}

// walks the IR below n; everything under a SEQ that gives a value is inside a value
attach fn suspends_in(this: checker&, n: u32, in_value: bool) -> compile_error!void {
    var inner = in_value;
    match (this.ir.at(n).kind) {
        .LABEL(l) => {
            if (in_value) {
                for (i) in 0..this.cx.suspend_labels.len {
                    if (*this.cx.suspend_labels.at(i) == l) {
                        return fails(*this.cx.suspends.at(i), "suspend can't go inside something that gives a value (a match, loop or block used as a value)");
                    }
                }
            }
            return;
        },
        .SEQ(stmts, v) => {
            if (v != null) {
                inner = true;
            }
        },
        default => {},
    }
    var kids: std::vec<u32> = {};
    this.ir.kids(n, &kids);
    for (k&) in kids.items() {
        try this.suspends_in(*k, inner);
    }
}

// an async fn that starts itself with `async` would have a frame containing itself
attach fn check_frame_cycles(this: checker&) -> compile_error!void {
    var starts: std::vec<u32> = {};
    for (f&) in this.frames.items() {
        put(&starts, f.fn_idx);
    }
    sort_u32(&starts);
    for (start&) in starts.items() {
        var stack = nodes(*start);
        var seen: idset = {};
        while (stack.len > 0) {
            val i = *stack.at(stack.len - 1);
            stack.pop();
            val fields = copy this.frame_of(i).fields;
            for (fd&) in fields.items() {
                match (*this.t.get(fd.ty)) {
                    .FRAME(j) => {
                        if (j == *start) {
                            val inst = this.fi(*start);
                            return fail(this.item_of(inst.decl).span, fmt("'{}' starts itself with async, so its frame would contain itself; call or await it instead", S(inst.name)));
                        }
                        if (seen.add(j) && this.has_frame(j)) {
                            put(&stack, j);
                        }
                    },
                    default => {},
                }
            }
        }
    }
}

attach fn has_frame(this: checker&, idx: u32) -> bool {
    for (f&) in this.frames.items() {
        if (f.fn_idx == idx) {
            return true;
        }
    }
    return false;
}

// insertion sort: there are only a few frames
fn sort_u32(v: std::vec<u32>&) -> void {
    for (i) in 1..v.len {
        var j = i;
        while (j > 0 && *v.at(j - 1) > *v.at(j)) {
            swap(v.at(j - 1), v.at(j));
            j -= 1;
        }
    }
}
