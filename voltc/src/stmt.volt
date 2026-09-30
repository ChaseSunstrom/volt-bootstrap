// Statements and control flow: a port of bootstrap/check/stmt.rs.
use std::mem;

struct code {
    c: u32;    // a statement
    div: bool; // always diverges
}

// a local narrowed by a condition (cond): the name or place key it shadows, and the narrowed local
struct narrow {
    key: str;
    l: local;
}

// how many loops (not labeled blocks) are around this point
attach fn loops_around(this: checker&) -> usize {
    var n: usize = 0;
    for (l&) in this.cx.loops.items() {
        if (!l.is_block) {
            n += 1;
        }
    }
    return n;
}

// declare a local in the innermost scope and return its place (a frame field in an async fn: slot)
attach fn new_local(this: checker&, name: str, t: u32, mutable: bool) -> u32 {
    val c = this.slot(name, t);
    val loops = this.loops_around();
    this.scope_top().vars.put(name, { c: c, ty: t, mutable: mutable, loops: loops });
    if (this.opts.lsp) {
        this.lsp_add_local(c, name, t, this.name_span(this.lsp_at, name));
    }
    return c;
}

// `T c = init` for a local, `c = init` for a frame field
attach fn decl_at(this: checker&, place: u32, init: u32?) -> u32 {
    match (this.ir.at(place).kind) {
        .LOCAL(id) => { return this.ir.decl(id, init); },
        default => {
            if (init) {
                return this.ir.assign(place, init);
            }
            return this.nop();
        },
    }
}

// `{ ... }` with its own scope
attach fn block_code(this: checker&, b: block&) -> compile_error!code {
    put(&this.cx.scopes, {});
    val r = this.block_scoped(b);
    this.cx.scopes.pop();
    return move r;
}

// block_code's body: the statements, then the scope's exits unless it diverges
attach fn block_scoped(this: checker&, b: block&) -> compile_error!code {
    var stmts: std::vec<u32> = {};
    var div = false;
    for (s&) in b.stmts.items() {
        val c = try this.stmt(s);
        put(&stmts, c.c);
        div = div || c.div;
    }
    if (!div) {
        val sc = this.cx.scopes.len - 1;
        for (x&) in (try this.scope_exit_code(sc, sc, false)).items() {
            put(&stmts, *x);
        }
    }
    return { c: this.ir.block(move stmts), div: div };
}

// one statement and whether it always diverges; defer/errdefer only register an exit
attach fn stmt(this: checker&, s: stmt&) -> compile_error!code {
    this.lsp_at = s.span;
    match (s.kind) {
        .LET(l&) => { return this.let_stmt(l); },
        .EXPR(e&) => {
            val v = try this.expr(e, null);
            val never = v.ty == NEVER;
            return { c: try this.discard(v), div: never };
        },
        .DEFER(e&) => {
            put(&this.scope_top().exits, exit::DEFER(e, false));
            return { c: this.nop(), div: false };
        },
        .ERR_DEFER(e&) => {
            put(&this.scope_top().exits, exit::DEFER(e, true));
            return { c: this.nop(), div: false };
        },
        .SUSPEND => { return { c: try this.suspend_code(s.span), div: false }; },
        .RESUME(e&) => { return { c: try this.resume_code(e, s.span), div: false }; },
    }
}

// Type for a declaration, filling in `T[]` lengths from the initializer.
attach fn decl_type(this: checker&, t: ty&, init: expr*) -> compile_error!u32 {
    val e = this.cx.env;
    match (t.kind) {
        .ARRAY(inner, n) => {
            if (n == null) {
                val elem = try this.resolve_type(inner, e);
                var count: i128 = 0;
                val ie = init ?? return fails(t.span, "T[] takes its length from an initializer");
                var done = false;
                match (ie.kind) {
                    .LITERAL(entries) => {
                        count = @cast<i128>(entries.len);
                        done = true;
                    },
                    .RANGE(lo, hi, incl) => {
                        if (lo != null && hi != null) {
                            count = (try this.const_int(hi.value, e)) - (try this.const_int(lo.value, e));
                            if (incl) {
                                count += 1;
                            }
                            done = true;
                        }
                    },
                    default => {},
                }
                if (!done) {
                    val v = try this.expr(ie, null);
                    match (*this.t.get(v.ty)) {
                        .ARRAY(x, len) => { count = @cast<i128>(len); },
                        default => { return fails(t.span, "T[] needs an initializer with a known length"); },
                    }
                }
                val len = try array_len(count, t.span);
                return this.t.intern(tyk::ARRAY(elem, len));
            }
        },
        default => {},
    }
    return this.resolve_type(t, e);
}

// `var`/`val`: check the initializer against the declared type (or take its type), then bind a
// name or destructure a tuple. The value moves in.
attach fn let_stmt(this: checker&, l: let_stmt&) -> compile_error!code {
    if (l.init) {
        match (l.init.kind) {
            .ASYNC(call) => { return this.async_let(l, call); },
            default => {},
        }
    }
    if (l.is_comptime) {
        try this.ct_let(l);
        return { c: this.nop(), div: false };
    }
    var decl_ty: u32? = null;
    if (l.ty) {
        decl_ty = try this.decl_type(&l.ty, ptr_of(&l.init));
    }
    var v = vnew(0, 0);
    if (l.init) {
        val init = &l.init;
        if (decl_ty) {
            val t = decl_ty;
            val x = try this.expr(init, t);
            v = try this.take_into(x, t, init.span);
        } else {
            val x = try this.expr(init, null);
            if (x.ty == NULL_TY) {
                return fails(init.span, "can't tell the type of null here; add a type: var x: T? = null");
            }
            if (x.ty == VOID) {
                return fails(init.span, "this has no value");
            }
            v = try this.take(x, init.span);
        }
    } else if (decl_ty) {
        v = try this.zero_value(decl_ty, l.span);
    } else {
        return fails(l.span, "a variable needs a type or an initializer");
    }
    if (v.ty == NEVER) {
        return { c: v.c, div: true };
    }
    val t = v.ty;
    match (l.pat.kind) {
        .BIND(name) => {
            if (l.is_static) {
                // a static, shared by every call (and every frame)
                var g = S("static_");
                g.append(name);
                val gname = this.fresh_c_name(g.as_str());
                put(&this.ir.globals, { name: gname, ty: t, init: v.c, mutable: l.mutable, link: linkage::STATIC, origin: l.span });
                val place = this.ir.node(ir_kind::GLOBAL(@cast<u32>(this.ir.globals.len - 1)), t);
                val loops = this.loops_around();
                this.scope_top().vars.put(name, { c: place, ty: t, mutable: l.mutable, loops: loops });
                return { c: this.nop(), div: false };
            }
            this.lsp_at = l.pat.span;
            val o = try this.owned_local(name, t, l.mutable);
            var stmts: std::vec<u32> = {};
            put(&stmts, this.decl_at(o.c, v.c));
            if (o.flag) {
                put(&stmts, o.flag);
            }
            return { c: this.ir.block(move stmts), div: false };
        },
        .TUPLE(pats) => {
            var ts: std::vec<u32> = {};
            match (*this.t.get(t)) {
                .TUPLE(x, names) => { ts = copy x; },
                default => { return fail(l.pat.span, fmt("can't destructure a {}", this.ty_name(t))); },
            }
            if (ts.len != pats.len) {
                return fail(l.pat.span, fmt2("expected {} names, the tuple has {}", unum(@cast<u64>(pats.len)), unum(@cast<u64>(ts.len))));
            }
            val tmp = this.tmp_local("t", t);
            var stmts: std::vec<u32> = {};
            put(&stmts, this.ir.decl(tmp.id, v.c));
            for (i) in 0..pats.len {
                val p = pats.at(i);
                var name = "";
                match (p.kind) {
                    .BIND(n) => { name = n; },
                    default => { return fails(p.span, "expected a name"); },
                }
                val et = *ts.at(i);
                this.lsp_at = p.span;
                val o = try this.owned_local(name, et, l.mutable);
                put(&stmts, this.decl_at(o.c, this.ir.field(tmp.c, @cast<u32>(i), et)));
                if (o.flag) {
                    put(&stmts, o.flag);
                }
            }
            return { c: this.ir.block(move stmts), div: false };
        },
        default => { return fails(l.pat.span, "expected a name or (a, b)"); },
    }
}

// value of `var x: T;` with no initializer
attach fn zero_value(this: checker&, t: u32, span: span) -> compile_error!tval {
    match (*this.t.get(t)) {
        .STRUCT(sid) => {
            if (this.header_struct(sid)) {
                return vpure(t, this.ir.zero(t));
            }
            val n = (try this.struct_fields(sid, span)).len;
            var inits: std::vec<field_init> = {};
            for (i) in 0..n {
                val f = *(try this.struct_fields(sid, span)).at(i);
                var v = vnew(0, 0);
                var is_ref = false;
                match (*this.t.get(f.ty)) {
                    .REF(x) => { is_ref = true; },
                    default => {},
                }
                if (f.fallback != null || this.t.opt_inner(f.ty) != null) {
                    v = try this.field_default(sid, &f, span);
                } else if (is_ref) {
                    return fail(span, fmt2("{} needs an initializer: field '{}' is a reference and can't default", this.ty_name(t), S(f.name)));
                } else {
                    v = try this.zero_value(f.ty, span);
                }
                if (f.ty != VOID) {
                    put(&inits, { field: @cast<u32>(i), value: v.c });
                }
            }
            return vpure(t, this.ir.node(ir_kind::AGG(move inits), t));
        },
        .REF(x) => { return fail(span, fmt("a {} needs an initializer (references can't be null)", this.ty_name(t))); },
        .OPT(x) => { return this.none(t); },
        default => { return vpure(t, this.ir.zero(t)); },
    }
}

// ---------- exits ----------

// deferred code for scopes [to, from] (innermost first), each checked in its own scope
attach fn scope_exit_code(this: checker&, from: usize, to: usize, is_err: bool) -> compile_error!std::vec<u32> {
    this.cx.no_suspend += 1;
    val r = this.scope_exit_inner(from, to, is_err);
    this.cx.no_suspend -= 1;
    return move r;
}

attach fn scope_exit_inner(this: checker&, from: usize, to: usize, is_err: bool) -> compile_error!std::vec<u32> {
    var out: std::vec<u32> = {};
    var i = from + 1;
    while (i > to) {
        i -= 1;
        if (this.cx.scopes.at(i).exits.len == 0) {
            continue;
        }
        val exits = copy this.cx.scopes.at(i).exits;
        // the defers see only the scopes up to theirs
        var hidden: std::vec<scope> = {};
        while (this.cx.scopes.len > i + 1) {
            put(&hidden, this.cx.scopes.pop() ?? return fails({}, ""));
        }
        val r = this.run_exits(&exits, is_err, &out);
        while (hidden.len > 0) {
            put(&this.cx.scopes, hidden.pop() ?? return fails({}, ""));
        }
        try r;
    }
    return move out;
}

// append the code of a scope's exits, last registered first; errdefers only when is_err
attach fn run_exits(this: checker&, exits: std::vec<exit>&, is_err: bool, out: std::vec<u32>&) -> compile_error!void {
    var k = exits.len;
    while (k > 0) {
        k -= 1;
        match (*exits.at(k)) {
            .DEFER(e, only_err) => {
                if (only_err && !is_err) {
                    continue;
                }
                val v = try this.expr(e, null);
                put(out, v.c);
            },
            .DROP(c, d, flag) => {
                val pt = this.t.ref_to(this.ir.ty_of(c));
                put(out, this.ir.if_(flag, this.call_fn(d, nodes(this.ir.addr(c, pt)), VOID), null));
            },
        }
    }
}

// does any scope from 0 to `from` have an errdefer?
attach fn has_errdefer(this: checker&, from: usize) -> bool {
    for (i) in 0..(from + 1) {
        for (x&) in this.cx.scopes.at(i).exits.items() {
            match (*x) {
                .DEFER(e, only_err) => {
                    if (only_err) {
                        return true;
                    }
                },
                default => {},
            }
        }
    }
    return false;
}

// `return`: the value moves out, then every scope's exits run (errdefers too when an error union
// return value holds an error)
attach fn ret(this: checker&, v: expr*, span: span) -> compile_error!tval {
    val rt = this.cx.ret;
    var is_eu = false;
    var eu_void = false;
    match (*this.t.get(rt)) {
        .ERR_UNION(e, t) => {
            is_eu = true;
            eu_void = t == VOID;
        },
        default => {},
    }
    var value: tval? = null;
    if (v) {
        val e = v;
        this.cx.exiting += 1;
        val x = this.expr(e, rt) catch |er| {
            this.cx.exiting -= 1;
            return copy er;
        };
        val r = this.take_into(x, rt, e.span);
        this.cx.exiting -= 1;
        value = try r;
    } else if (rt == VOID) {
        value = null;
    } else if (eu_void) {
        value = vpure(rt, this.ir.zero(rt));
    } else {
        return fail(span, fmt("return needs a {} value", this.ty_name(rt)));
    }
    val top = this.cx.scopes.len - 1;
    var defers = try this.scope_exit_code(top, 0, false);
    val slot = this.ret_slot();
    if (is_eu) {
        val err_defers = try this.scope_exit_code(top, 0, true);
        if (this.has_errdefer(top)) {
            val code = this.eu_code(rt, slot.c);
            val both = this.ir.if_(this.nonzero(code), this.ir.block(move err_defers), this.ir.block(copy defers));
            defers = nodes(both);
        }
    }
    if (value != null && (value ?? vnew(0, 0)).ty == NEVER) {
        return vnew(NEVER, (value ?? vnew(0, 0)).c);
    }
    var vc: u32? = null;
    if (value) {
        vc = (value).c;
    }
    return vnew(NEVER, this.fn_exit(vc, move defers, slot));
}

// the loop a break/continue targets: the one with the label, else the innermost loop (a block
// only by label)
attach fn find_loop(this: checker&, label: str?, for_continue: bool, span: span) -> compile_error!usize {
    var i = this.cx.loops.len;
    while (i > 0) {
        i -= 1;
        val l = this.cx.loops.at(i);
        var hit = false;
        if (label) {
            hit = l.label != null && (l.label ?? "") == (label);
        } else {
            hit = !l.is_block;
        }
        if (hit) {
            if (for_continue && l.is_block) {
                return fails(span, "continue needs a loop, not a block");
            }
            return i;
        }
    }
    if (label) {
        return fail(span, fmt("no loop or block labeled :{} around here", S(label)));
    }
    return fails(span, "break/continue outside of a loop");
}

// `break` (with a value, for a loop or labeled block): run the exits of the scopes it leaves, then
// jump out
attach fn brk(this: checker&, label: str?, v: expr*, span: span) -> compile_error!tval {
    val li = try this.find_loop(label, false, span);
    var stmts: std::vec<u32> = {};
    if (v) {
        val e = v;
        if (!this.cx.loops.at(li).can_value) {
            return fails(e.span, "only loop and labeled blocks can break with a value");
        }
        this.cx.exiting += 1;
        val g = this.expr(e, this.cx.loops.at(li).break_ty) catch |er| {
            this.cx.exiting -= 1;
            return copy er;
        };
        val got = this.take(g, e.span);
        this.cx.exiting -= 1;
        var value = try got;
        val bt = this.cx.loops.at(li).break_ty;
        if (bt) {
            value = try this.coerce(value, bt, e.span);
        } else {
            if (value.ty == VOID || value.ty == NULL_TY) {
                return fails(e.span, "break needs a value with a type here");
            }
            this.cx.loops.at(li).break_ty = value.ty;
        }
        val res = this.loop_result(li);
        put(&stmts, this.ir.assign(res, value.c));
    } else if (this.cx.loops.at(li).break_ty != null && this.cx.loops.at(li).can_value) {
        return fails(span, "this loop breaks with a value elsewhere, so this break needs one too");
    }
    this.cx.loops.at(li).has_break = true;
    val moved = copy this.cx.moved;
    this.cx.loops.at(li).moved_at_break.add_all(&moved);
    val top = this.cx.scopes.len - 1;
    val depth = this.cx.loops.at(li).depth;
    for (x&) in (try this.scope_exit_code(top, depth, false)).items() {
        put(&stmts, *x);
    }
    put(&stmts, this.ir.goto_(this.cx.loops.at(li).brk));
    return vnew(NEVER, this.ir.node(ir_kind::BLOCK(move stmts), NEVER));
}

// where break values go (made when the type is known)
attach fn loop_result(this: checker&, li: usize) -> u32 {
    val have = this.cx.loops.at(li).result;
    if (have) {
        return have;
    }
    val t = this.cx.loops.at(li).break_ty ?? VOID;
    val r = this.tmp_local("lr", t);
    this.cx.loops.at(li).result = r.c;
    this.cx.loops.at(li).result_id = r.id;
    return r.c;
}

// `continue`: run the exits of the scopes it leaves, then jump to the loop's next round
attach fn cont(this: checker&, label: str?, span: span) -> compile_error!tval {
    val li = try this.find_loop(label, true, span);
    val top = this.cx.scopes.len - 1;
    val depth = this.cx.loops.at(li).depth;
    var stmts: std::vec<u32> = {};
    if (top >= depth) {
        for (x&) in (try this.scope_exit_code(top, depth, false)).items() {
            put(&stmts, *x);
        }
    }
    put(&stmts, this.ir.goto_(this.cx.loops.at(li).cont ?? 0));
    return vnew(NEVER, this.ir.node(ir_kind::BLOCK(move stmts), NEVER));
}

// ---------- control flow ----------

// start a loop or labeled block: its labels; the result local comes later (loop_result)
attach fn push_loop(this: checker&, label: str?, is_block: bool, value: bool, want: u32?) -> usize {
    this.cx.next_id += 1;
    var cont: u32? = null;
    if (!is_block) {
        cont = this.ir.label();
    }
    var bt: u32? = null;
    if (value) {
        bt = want;
    }
    put(&this.cx.loops, { label: label, is_block: is_block, brk: this.ir.label(), cont: cont, result: null, break_ty: bt, can_value: value, depth: this.cx.scopes.len });
    return this.cx.loops.len - 1;
}

// wrap finished loop code as a value (break with value) or a statement
attach fn finish_loop(this: checker&, body: std::vec<u32>, body_div: bool, span: span, value_needs_break: bool) -> compile_error!tval {
    val lc = this.cx.loops.pop() ?? return fails(span, "");
    // what was moved on the way to a break is moved after the loop too
    this.cx.moved.add_all(&lc.moved_at_break);
    var stmts = move body;
    put(&stmts, this.ir.label_at(lc.brk));
    if (lc.can_value && lc.break_ty != null && lc.has_break) {
        if (value_needs_break && !body_div) {
            return fails(span, "this block needs to end with a break that gives its value");
        }
        val t = lc.break_ty ?? VOID;
        val res = lc.result ?? return fails(span, "");
        var all: std::vec<u32> = {};
        put(&all, this.ir.decl(lc.result_id, null));
        for (s&) in stmts.items() {
            put(&all, *s);
        }
        return vnew(t, this.ir.seq(move all, res, t));
    }
    var t = VOID;
    if (body_div && !lc.has_break) {
        t = NEVER;
    }
    return vnew(t, this.ir.node(ir_kind::BLOCK(move stmts), t));
}

// `{ ... }`, or a labeled block that break can leave with a value
attach fn block_expr(this: checker&, label: str?, b: block&, want: u32?, span: span) -> compile_error!tval {
    if (label == null) {
        val bc = try this.block_code(b);
        if (bc.div) {
            return vnew(NEVER, bc.c);
        }
        return vnew(VOID, bc.c);
    }
    this.push_loop(label, true, true, want);
    val bc = this.block_code(b) catch |e| {
        this.cx.loops.pop();
        return copy e;
    };
    return this.finish_loop(nodes(bc.c), bc.div, span, true);
}

// `loop { ... }`: its value is what a break gives; never, if nothing breaks out
attach fn loop_expr(this: checker&, label: str?, b: block&, want: u32?, span: span) -> compile_error!tval {
    val li = this.push_loop(label, false, true, want);
    val cont = this.cx.loops.at(li).cont ?? 0;
    val bc = this.block_code(b) catch |e| {
        this.cx.loops.pop();
        return copy e;
    };
    val body = this.ir.block(nodes2(bc.c, this.ir.label_at(cont)));
    return this.finish_loop(nodes(this.ir.node(ir_kind::LOOP(body), VOID)), true, span, false);
}

// `while (cond) { ... }`; the condition may narrow an optional or pointer inside the body
attach fn while_expr(this: checker&, label: str?, c: expr&, b: block&, span: span) -> compile_error!tval {
    val li = this.push_loop(label, false, false, null);
    val cont = this.cx.loops.at(li).cont ?? 0;
    val brk_l = this.cx.loops.at(li).brk;
    val cd = this.cond(c) catch |e| {
        this.cx.loops.pop();
        return copy e;
    };
    this.push_narrow(&cd.narrow);
    val r = this.block_code(b);
    this.pop_narrow(&cd.narrow);
    val bc = r catch |e| {
        this.cx.loops.pop();
        return copy e;
    };
    val stop = this.ir.if_(this.ir.unary(unop_ir::NOT, cd.test, BOOL), this.ir.goto_(brk_l), null);
    val body = this.ir.block(nodes3(stop, bc.c, this.ir.label_at(cont)));
    return this.finish_loop(nodes(this.ir.node(ir_kind::LOOP(body), VOID)), false, span, false);
}

// put a narrowed local (from cond), if any, in a scope of its own; pop_narrow drops it
attach fn push_narrow(this: checker&, n: narrow?&) -> void {
    if ((*n).none) {
        return;
    }
    var s: scope = {};
    s.vars.put((*n).value.key, (*n).value.l);
    put(&this.cx.scopes, move s);
}

attach fn pop_narrow(this: checker&, n: narrow?&) -> void {
    if (!(*n).none) {
        this.cx.scopes.pop();
    }
}

// if/else (a statement); the condition may narrow an optional or pointer in the then branch
attach fn if_expr(this: checker&, c: expr&, then: block&, els: expr*, span: span) -> compile_error!tval {
    val cd = try this.cond(c);
    // moves are tracked per path: a branch that leaves (return, break...) doesn't reach the code
    // after the if, so its moves don't count there (a break's count after its loop)
    val before = copy this.cx.moved;
    this.push_narrow(&cd.narrow);
    val tr = this.block_code(then);
    this.pop_narrow(&cd.narrow);
    val tc = try tr;
    var after_then: idset = {};
    if (tc.div) {
        after_then = copy before;
    } else {
        after_then = copy this.cx.moved;
    }
    this.cx.moved = copy before;
    var ec: u32? = null;
    var ediv = false;
    if (els) {
        val v = try this.expr(els, null);
        ec = v.c;
        ediv = v.ty == NEVER;
    }
    if (ediv) {
        this.cx.moved = copy before;
    }
    this.cx.moved.add_all(&after_then);
    var t = VOID;
    if (tc.div && ediv) {
        t = NEVER;
    }
    return vnew(t, this.ir.node(ir_kind::IF(cd.test, tc.c, ec), t));
}

// `for (x)`, `for (x, i)`, `for (x&)` over a range, array, slice, str or range value; a comptime
// for is unrolled
attach fn for_expr(this: checker&, f: for_loop&, want: u32?, span: span) -> compile_error!tval {
    if (f.is_comptime) {
        return this.ct_for_unroll(f, span);
    }
    if (f.bindings.len == 0 || f.bindings.len > 2) {
        return fails(span, "for takes one or two names: for (value) or for (value, index)");
    }
    put(&this.cx.scopes, {});
    val r = this.for_inner(f, want, span);
    this.cx.scopes.pop();
    return move r;
}

// A runtime for loop, in a scope of its own. An accumulator (`[var acc = init]`) is declared
// first and is the loop's value; the loop state lives in slots, so an async body can suspend.
attach fn for_inner(this: checker&, f: for_loop&, want: u32?, span: span) -> compile_error!tval {
    var pre: std::vec<u32> = {};
    var init_flags: std::vec<u32> = {}; // the kept temporaries' live flags, set before the iterable
    var acc_decl: u32? = null;
    var acc: local? = null;
    if (f.acc) {
        val a = &f.acc;
        acc_decl = (try this.let_stmt(a)).c;
        match (a.pat.kind) {
            .BIND(n) => { acc = this.lookup_local(n); },
            default => {},
        }
    }
    // the iterable
    var elem_ty: u32 = 0;
    var elem: u32 = 0;       // the element (a place when addressable)
    var index: u32 = 0;
    var addressable = false;
    var head: std::vec<u32> = {};  // before the body, inside the loop
    var tail: std::vec<u32> = {};  // after the continue label
    var init: std::vec<u32> = {};  // before the loop
    var guard: u32? = null;        // the loop runs only if this holds (ranges)
    var stop: u32? = null;         // leave when this holds (at the top of each round)
    var range_it = false;
    match (f.iter.kind) {
        .RANGE(lo, hi, incl) => {
            if (lo != null && hi != null) {
                range_it = true;
                val le: expr& = lo.value;
                val he: expr& = hi.value;
                var a = try this.expr(le, null);
                var b = try this.expr(he, a.ty);
                if (a.lit != null && b.lit == null) {
                    a = try this.coerce(a, b.ty, le.span);
                } else {
                    b = try this.coerce(b, a.ty, he.span);
                }
                if (this.t.int_of(a.ty) == null) {
                    return fails(f.iter.span, "ranges need integers");
                }
                val t = a.ty;
                // loop state lives in slots: in an async fn it must survive a suspend in the body
                val lo_v = this.slot("_lo", t);
                val hi_v = this.slot("_hi", t);
                val it = this.slot("_it", t);
                put(&pre, this.decl_at(lo_v, a.c));
                put(&pre, this.decl_at(hi_v, b.c));
                var last = hi_v;
                var cmp = binop_ir::LT;
                if (incl) {
                    cmp = binop_ir::LE;
                } else {
                    last = this.ir.binary(binop_ir::SUB, hi_v, this.ir.int(1, t), t);
                }
                guard = this.ir.binary(cmp, lo_v, hi_v, BOOL);
                put(&init, this.decl_at(it, lo_v));
                put(&tail, this.ir.if_(this.ir.binary(binop_ir::EQ, it, last, BOOL), this.ir.goto_(0), null));
                put(&tail, this.ir.assign(it, this.ir.binary(binop_ir::ADD, it, this.ir.int(1, t), t)));
                elem_ty = t;
                elem = it;
                index = this.ir.conv(this.ir.binary(binop_ir::SUB, it, lo_v, t), USIZE);
            }
        },
        default => {},
    }
    // deleting the iterable's temporaries once the loop is done
    var after: std::vec<u32> = {};
    if (!range_it) {
        // temporaries the iterable makes (the vec in `f().items()`) live until the loop ends
        val was = this.cx.keeping;
        val base = this.cx.kept.len;
        this.cx.keeping = true;
        val vr = this.expr(&f.iter, null);
        this.cx.keeping = was;
        var kept: std::vec<kept_temp> = {};
        while (this.cx.kept.len > base) {
            put(&kept, this.cx.kept.pop() ?? { c: 0, ty: 0, flag: 0 });
        }
        val v = try vr;
        var i = kept.len;
        while (i > 0) {
            i -= 1;
            val k = *kept.at(i);
            put(&init_flags, this.decl_at(k.flag, this.ir.boolean(false)));
            if (try this.needs_drop(k.ty)) {
                val d = try this.drop_fn(k.ty);
                val del = this.call_fn(d, nodes(this.ir.addr(k.c, this.t.ref_to(k.ty))), VOID);
                put(&after, this.ir.if_(k.flag, del, null));
                put(&this.scope_top().exits, exit::DROP(k.c, d, k.flag));
            }
        }
        if (!v.lv && (try this.needs_drop(v.ty))) {
            return fails(f.iter.span, "store this in a variable before looping over it (its elements own memory)");
        }
        var k = this.slot("_k", USIZE);
        var t = v.ty;
        var through_ref = false;
        val inner = this.t.ref_inner(v.ty);
        if (inner) {
            t = inner;
            through_ref = true;
        }
        var is_range_val = false;
        var is_iter = false;
        match (*this.t.get(t)) {
            .ARRAY(et, n) => {
                val pt = this.t.ref_to(t);
                val p = this.slot("_a", pt);
                var addr = v.c;
                if (!through_ref) {
                    if (v.lv) {
                        addr = this.ir.addr(v.c, pt);
                    } else {
                        val tmpv = this.slot("_av", t);
                        put(&pre, this.decl_at(tmpv, v.c));
                        addr = this.ir.addr(tmpv, pt);
                    }
                }
                put(&pre, this.decl_at(p, addr));
                elem_ty = et;
                elem = this.ir.index(this.ir.deref(p, t), k, et);
                stop = this.ir.binary(binop_ir::GE, k, this.ir.int(@cast<i128>(n), USIZE), BOOL);
            },
            .SLICE(et) => {
                val s = this.slot("_sl", t);
                var sv = v.c;
                if (through_ref) {
                    sv = this.ir.deref(v.c, t);
                }
                put(&pre, this.decl_at(s, sv));
                elem_ty = et;
                elem = this.ir.index(this.ir.field(s, 0, this.t.intern(tyk::PTR(et))), k, et);
                stop = this.ir.binary(binop_ir::GE, k, this.ir.field(s, 1, USIZE), BOOL);
            },
            .STR => {
                if (f.bindings.at(0).by_ref) {
                    return fails(f.bindings.at(0).span, "a str is read-only, so (x&) can't point into it; loop over it by value instead");
                }
                val s = this.slot("_sl", STR);
                put(&pre, this.decl_at(s, v.c));
                elem_ty = U8;
                elem = this.ir.index(this.ir.field(s, 0, this.t.intern(tyk::PTR(U8))), k, U8);
                stop = this.ir.binary(binop_ir::GE, k, this.ir.field(s, 1, USIZE), BOOL);
            },
            .RANGE(et) => {
                val r = this.slot("_r", t);
                put(&pre, this.decl_at(r, v.c));
                k = this.slot("_k", et);
                put(&init, this.decl_at(k, this.ir.field(r, 0, et)));
                stop = this.ir.binary(binop_ir::GE, k, this.ir.field(r, 1, et), BOOL);
                put(&tail, this.ir.assign(k, this.ir.binary(binop_ir::ADD, k, this.ir.int(1, et), et)));
                elem_ty = et;
                elem = k;
                index = this.ir.conv(this.ir.binary(binop_ir::SUB, k, this.ir.field(r, 0, et), et), USIZE);
                is_range_val = true;
            },
            default => {
                // a type that attaches next(this: T&) -> X? (or -> X*) is an iterator: next until it's
                // null. A pointer binds as an X&
                val h = (try this.hook(t, "next")) ?? return fail(f.iter.span, fmt2("can't loop over a {} (a type loops when it attaches next(this: {}&) -> T? or -> T*)", this.ty_name(v.ty), this.ty_name(t)));
                this.use_fn(h);
                val ot = this.fi(h).ret;
                val pt = this.t.ref_to(t);
                val p = this.slot("_ip", pt);
                // a var (or a reference to one) is advanced in place; a val or a temporary is copied
                var addr = v.c;
                if (!through_ref) {
                    if (v.lv && v.mutable) {
                        addr = this.ir.addr(v.c, pt);
                    } else {
                        val tv = this.slot("_iv", t);
                        put(&pre, this.decl_at(tv, v.c));
                        addr = this.ir.addr(tv, pt);
                    }
                }
                put(&pre, this.decl_at(p, addr));
                val nx = this.slot("_nx", ot);
                put(&pre, this.decl_at(nx, this.ir.zero(ot)));
                val step = this.ir.assign(nx, this.call_fn(this.fi(h).ir, nodes(p), ot));
                var has = this.ir.boolean(false);
                match (*this.t.get(ot)) {
                    .PTR(pt2) => {
                        has = this.ir.binary(binop_ir::NE, nx, this.ir.node(ir_kind::NULLPTR, ot), BOOL);
                        elem_ty = this.t.ref_to(pt2);
                        elem = this.ir.conv(nx, elem_ty);
                    },
                    default => {
                        val parts = this.opt_parts(ot, nx);
                        has = parts.has;
                        elem_ty = this.t.opt_inner(ot) ?? 0;
                        elem = parts.value;
                    },
                }
                stop = this.ir.seq(nodes(step), this.ir.unary(unop_ir::NOT, has, BOOL), BOOL);
                is_iter = true;
            },
        }
        if (!is_range_val) {
            put(&init, this.decl_at(k, this.ir.int(0, USIZE)));
            put(&tail, this.ir.assign(k, this.ir.binary(binop_ir::ADD, k, this.ir.int(1, USIZE), USIZE)));
            index = k;
            addressable = !is_iter;
        }
    }
    val li = this.push_loop(f.label, false, false, null);
    val cont = this.cx.loops.at(li).cont ?? 0;
    val brk_l = this.cx.loops.at(li).brk;
    // the range's "last round" check leaves the loop
    for (s&) in tail.items() {
        match (this.ir.at(*s).kind) {
            .IF(c, then, e) => {
                match (this.ir.at(then).kind) {
                    .GOTO(l) => {
                        if (l == 0) {
                            this.ir.at(then).kind = ir_kind::GOTO(brk_l);
                        }
                    },
                    default => {},
                }
            },
            default => {},
        }
    }
    put(&this.cx.scopes, {});
    val r = this.for_body(f, elem_ty, elem, index, addressable);
    this.cx.scopes.pop();
    val binds_body = r catch |e| {
        this.cx.loops.pop();
        return copy e;
    };
    var inner: std::vec<u32> = {};
    if (stop) {
        put(&inner, this.ir.if_(stop, this.ir.goto_(brk_l), null));
    }
    for (s&) in binds_body.items() {
        put(&inner, *s);
    }
    put(&inner, this.ir.label_at(cont));
    for (s&) in tail.items() {
        put(&inner, *s);
    }
    var lp: std::vec<u32> = copy init;
    put(&lp, this.ir.node(ir_kind::LOOP(this.ir.block(move inner)), VOID));
    var all = move init_flags;
    for (s&) in pre.items() {
        put(&all, *s);
    }
    if (guard) {
        put(&all, this.ir.if_(guard, this.ir.block(move lp), null));
    } else {
        for (s&) in lp.items() {
            put(&all, *s);
        }
    }
    var v = try this.finish_loop(move all, false, span, false);
    if (after.len > 0) {
        var stmts = nodes(v.c);
        for (s&) in after.items() {
            put(&stmts, *s);
        }
        v.c = this.ir.block(move stmts);
    }
    if (acc) {
        val a = acc;
        return vnew(a.ty, this.ir.seq(nodes2(acc_decl ?? this.nop(), v.c), a.c, a.ty));
    }
    return v;
}

// the bindings and the body of one round
attach fn for_body(this: checker&, f: for_loop&, elem_ty: u32, elem: u32, index: u32, addressable: bool) -> compile_error!std::vec<u32> {
    var out: std::vec<u32> = {};
    val b0 = f.bindings.at(0);
    if (b0.by_ref) {
        if (!addressable) {
            return fails(b0.span, "(x&) needs something stored to point at, like an array or slice");
        }
        val rt = this.t.ref_to(elem_ty);
        val c = this.new_local(b0.name, rt, false);
        put(&out, this.decl_at(c, this.ir.addr(elem, rt)));
    } else {
        val c = this.new_local(b0.name, elem_ty, false);
        put(&out, this.decl_at(c, elem));
    }
    if (f.bindings.len > 1) {
        val c = this.new_local(f.bindings.at(1).name, USIZE, false);
        put(&out, this.decl_at(c, index));
    }
    if (f.map) {
        val v = try this.expr(&f.map, null);
        if (v.ty == VOID || v.ty == NEVER) {
            return fails(f.map.span, "=> needs a value");
        }
        val c = this.new_local(b0.name, v.ty, false);
        put(&out, this.decl_at(c, v.c));
    }
    val bc = try this.block_code(&f.body);
    put(&out, bc.c);
    return move out;
}
