// Async fns are stackless state machines, with no scheduler and no heap. A port of
// bootstrap/check/asyncs.rs. `async fn f` becomes a frame (resume state, cancel flag, result, and every
// param/local/loop counter that may live across a suspend) plus `bool f_step(frame&)`, which runs
// to the next suspend (false) or the end (true). `val fr = async f()` builds the frame in place and
// runs it to its first suspend, `resume fr` steps once, `await fr` steps until done and takes the
// result. A plain call (or `await f()`) runs a temporary frame to completion, and so does an entry
// (async_entry: main, an export or extern fn, a fn value), for callers that can't step it. A frame
// moves like any owned value, its bytes copied; one that may point into itself warns at the move
// (warn_frame_moves). Deleting an unfinished frame resumes it in cancel mode, which runs its defers
// and deletes; a suspend in a defer pauses unless the frame is being cancelled.
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

// main, an export fn and an extern fn with a body are called from outside Volt, which can't step a
// frame: their C symbol runs it to its end (async_entry)
attach fn is_async_entry(this: checker&, idx: u32) -> bool {
    val f = this.fn_decl_of(this.fi(idx).decl) ?? return false;
    return f.is_async && f.body != null && (f.extern_abi != null || f.is_export || this.fi(idx).c_name == "v_main");
}

// the ir fn a call through a pointer reaches: for an async fn, one running its frame to its end
attach fn entry_ir(this: checker&, idx: u32) -> u32 {
    if (this.is_async_fn(idx)) {
        return this.async_entry(idx);
    }
    return this.fi(idx).ir;
}

// R f(args) { return f_run(f_frame(args)); }: an async fn run to its end, for callers that can't
// step its frame (C, the start code, a fn value). For an entry (is_async_entry) it takes the C
// symbol and its linkage, and the frame builder becomes f_frame, private
attach fn async_entry(this: checker&, idx: u32) -> u32 {
    val have = this.async_entries.get(idx);
    if (have) {
        return *have;
    }
    val a = this.async_fns(idx);
    val bf = this.fi(idx).ir;
    val ret = this.fi(idx).ret;
    var name = S(this.fi(idx).c_name);
    var link = linkage::STATIC;
    var real_name: str? = null;
    if (this.is_async_entry(idx)) {
        link = this.fn_linkage(idx);
        var bn = S(this.fi(idx).c_name);
        bn.append("_frame");
        val b = this.ir.fn_at(bf);
        b.name = this.intern(move bn);
        b.link = linkage::STATIC;
        real_name = b.real_name;
        b.real_name = null;
    } else {
        name.append("_entry");
    }
    val origin = this.item_of(this.fi(idx).decl).span;
    var irf: ir_fn = { name: this.intern(move name), params: {}, ret: ret, link: link, used: true, origin: origin, about: this.fi(idx).name };
    irf.real_name = real_name;
    var args: std::vec<u32> = {};
    val bl = copy this.ir.fn_at(bf).locals;
    for (pid&) in this.ir.fn_at(bf).params.items() {
        val pt = bl.at(@cast<usize>(*pid)).ty;
        put(&irf.locals, { name: bl.at(@cast<usize>(*pid)).name, ty: pt });
        val li = @cast<u32>(irf.locals.len - 1);
        put(&irf.params, li);
        put(&args, this.ir.node(ir_kind::LOCAL(li), pt));
    }
    put(&this.ir.fns, bx(move irf));
    val f = @cast<u32>(this.ir.fns.len - 1);
    put(&this.ir.order, f);
    this.async_entries.put(idx, f);
    if (link == linkage::EXTERNAL) {
        return f; // a linked library's export fn: defined there
    }
    val ft = this.t.intern(tyk::FRAME(idx));
    val run = this.call_fn(a.run, nodes(this.call_fn(bf, move args, ft)), ret);
    if (ret == VOID) {
        this.ir.fn_at(f).body = this.ir.block(nodes(run));
    } else {
        this.ir.fn_at(f).body = this.ir.block(nodes(this.ir.ret(run)));
    }
    put(&this.ir.bodies, f);
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
        var tail = copy defers;
        put(&tail, this.ir.assign(this.ir.field(this.frame_obj(), 0, U32), this.ir.int(VOLT_DONE, U32)));
        put(&tail, this.ir.ret(this.ir.boolean(true)));
        if (this.has_suspend(&defers)) {
            // a defer suspends: the exit goes out of line, to the step fn's top level, since a resume
            // label can't sit inside a value (an exit from inside an expression, as a try's)
            val l = this.ir.label();
            var blk = nodes(this.ir.label_at(l));
            extend(&blk, move tail);
            put(&this.cx.exit_blocks, this.ir.block(move blk));
            put(&stmts, this.ir.goto_(l));
        } else {
            extend(&stmts, move tail);
        }
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
// to its label. A frame cancelled while stopped here runs its cleanup and finishes instead. In exit code
// (a defer) it pauses only when the frame isn't being cancelled, and cancelled while paused there the
// frame carries on with the exit code, which finishes it (see scope_exit_code)
attach fn suspend_code(this: checker&, span: span) -> compile_error!u32 {
    if (this.cx.frame == null) {
        return fails(span, "suspend only works inside an async fn");
    }
    this.note_self_ref();
    put(&this.cx.suspends, span);
    val n = this.cx.suspends.len;
    val l = this.ir.label();
    put(&this.cx.suspend_labels, l);
    val obj = this.frame_obj();
    val state = this.ir.field(obj, 0, U32);
    if (this.cx.in_exit > 0) {
        val pause = this.ir.block(nodes2(this.ir.assign(state, this.ir.int(@cast<i128>(n), U32)), this.ir.ret(this.ir.boolean(false))));
        return this.ir.block(nodes2(this.ir.if_(this.ir.field(obj, 1, BOOL), this.nop(), pause), this.ir.label_at(l)));
    }
    // cancelled here (deleted before finishing): leave like a return, without a value
    val top = this.cx.scopes.len - 1;
    var cleanup = try this.scope_exit_code(top, 0, false);
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
    // a resume point in code compiled and then dropped is in neither: no case jumps to it
    var present: idset = {};
    this.labels_in(code, &present);
    for (b&) in this.cx.exit_blocks.items() {
        this.labels_in(*b, &present);
    }
    var cases: std::vec<case_arm> = {};
    put(&cases, { value: 0, body: this.nop() });
    for (i) in 0..this.cx.suspend_labels.len {
        val l = *this.cx.suspend_labels.at(i);
        if (present.has(l)) {
            put(&cases, { value: @cast<i128>(i) + 1, body: this.ir.goto_(l) });
        }
    }
    val sw = this.ir.node(ir_kind::SWITCH(state, move cases, this.ir.ret(this.ir.boolean(true))), VOID);
    var body = nodes2(sw, code);
    for (b&) in this.cx.exit_blocks.items() {
        try this.check_suspends(*b);
        put(&body, *b);
    }
    this.ir.fn_at(a.step).body = this.ir.block(move body);
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

// the labels in the code below n
attach fn labels_in(this: checker&, n: u32, into: idset&) -> void {
    match (this.ir.at(n).kind) {
        .LABEL(l) => {
            into.add(l);
            return;
        },
        default => {},
    }
    var kids: std::vec<u32> = {};
    this.ir.kids(n, &kids);
    for (k&) in kids.items() {
        this.labels_in(*k, into);
    }
}

// does code in xs hold a resume point (a suspend's label)?
attach fn has_suspend(this: checker&, xs: std::vec<u32>&) -> bool {
    for (x&) in xs.items() {
        if (this.suspend_below(*x)) {
            return true;
        }
    }
    return false;
}

attach fn suspend_below(this: checker&, n: u32) -> bool {
    match (this.ir.at(n).kind) {
        .LABEL(l) => {
            for (s&) in this.cx.suspend_labels.items() {
                if (*s == l) {
                    return true;
                }
            }
            return false;
        },
        default => {},
    }
    var kids: std::vec<u32> = {};
    this.ir.kids(n, &kids);
    for (k&) in kids.items() {
        if (this.suspend_below(*k)) {
            return true;
        }
    }
    return false;
}

// a local holding a reference to another of the frame's locals, in scope at a suspend: from there on
// the frame points into itself, so moving it would leave that reference pointing into the old frame
attach fn note_self_ref(this: checker&) -> void {
    if (!this.frame_of(this.cx.frame ?? 0).self_ref.is_empty()) {
        return;
    }
    var best: u32? = null;
    for (e) in this.cx.ref_holders.iter() {
        if (this.local_in_scope(*e.key) != null && (best == null || *e.key < (best ?? 0))) {
            best = *e.key;
        }
    }
    val k = best ?? return;
    val held = *(this.cx.ref_holders.get(k) ?? return);
    this.frame_of(this.cx.frame ?? 0).self_ref = fmt2("'{}' holds a reference to '{}'", S(this.local_at(k)), S(held));
}

// a frame moved while it may point into itself: the moved bytes still point into the old frame.
// Checked once every body is generated, since a move may come before its fn's body
attach fn warn_frame_moves(this: checker&) -> void {
    for (i) in 0..this.frame_moves.len {
        val m = *this.frame_moves.at(i);
        var again = false;
        for (j) in 0..i {
            if (same_span(this.frame_moves.at(j).span, m.span)) {
                again = true;
            }
        }
        var why = this.frame_self_ref(m.idx, 0);
        if (again || why.is_empty()) {
            continue;
        }
        var msg = fmt2("moving this frame of '{}' leaves it pointing into the old frame ({} across a suspend): resume or await it where it is", S(this.fi(m.idx).name), move why);
        put(&this.warnings, { span: m.span, msg: move msg, warning: true });
    }
}

// why frame idx may point into itself: a reference of its own, or one in a frame it holds
attach fn frame_self_ref(this: checker&, idx: u32, depth: u32) -> std::string {
    val own = copy this.frame_of(idx).self_ref;
    if (!own.is_empty() || depth > 32) {
        return own;
    }
    val fields = copy this.frame_of(idx).fields;
    for (fd&) in fields.items() {
        match (*this.t.get(fd.ty)) {
            .FRAME(j) => {
                val inner = this.frame_self_ref(j, depth + 1);
                if (!inner.is_empty()) {
                    return fmt2("it holds a frame of '{}', where {}", S(this.fi(j).name), move inner);
                }
            },
            default => {},
        }
    }
    return own;
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
                        return fails(*this.cx.suspends.at(i), "suspend can't go inside something that gives a value (a match, loop or block used as a value, or a defer run by a break or continue from inside an expression: x ?? break)");
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
