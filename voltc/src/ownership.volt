// Ownership: which types need delete, generated drop/copy glue, moves out of locals. A port of
// bootstrap/check/ownership.rs. A type needs delete if it attaches `delete`, is a box, or contains such a
// type. Owned locals get a runtime "live" flag, so conditional moves are handled; scope exits drop
// live owners in reverse.
use std::mem;

// whether a value of t must be deleted: it has a delete hook, is an @owns box, or holds such a value
// (memoized)
attach fn needs_drop(this: checker&, t: u32) -> compile_error!bool {
    val have = this.drop_memo.get(t);
    if (have) {
        return *have;
    }
    this.drop_memo.put(t, false); // recursion through a box is fine: box already says yes
    val r = this.needs_drop_uncached(t) catch |e| {
        // not an answer: the next function to ask (the run goes on after an error) tries again
        this.drop_memo.remove(t);
        return copy e;
    };
    this.drop_memo.put(t, r);
    return r;
}

attach fn needs_drop_uncached(this: checker&, t: u32) -> compile_error!bool {
    var r = false;
    match (*this.t.get(t)) {
        .STRUCT(s) => {
            if (this.box_inner(t) != null || (try this.hook(t, "delete")) != null) {
                r = true;
            } else {
                val n = (try this.struct_fields(s, {})).len;
                for (i) in 0..n {
                    val ft = (try this.struct_fields(s, {})).at(i).ty;
                    if (try this.needs_drop(ft)) {
                        r = true;
                    }
                }
            }
        },
        .ENUM(e) => {
            r = (try this.hook(t, "delete")) != null;
            val ps = copy *(try this.enum_payloads(e, {}));
            for (p&) in ps.items() {
                if (*p) {
                    if (try this.needs_drop(*p ?? 0)) {
                        r = true;
                    }
                }
            }
        },
        .TUPLE(ts, names) => {
            val xs = copy ts;
            for (x&) in xs.items() {
                if (try this.needs_drop(*x)) {
                    r = true;
                }
            }
        },
        .ARRAY(x, n) => { r = try this.needs_drop(x); },
        .OPT(x) => { r = try this.needs_drop(x); },
        .ERR_UNION(e, x) => { r = (try this.needs_drop(e)) || (try this.needs_drop(x)); },
        .CLOSURE(c) => {
            val caps = copy this.ci(c).caps;
            for (cp&) in caps.items() {
                if (try this.needs_drop(cp.ty)) {
                    r = true;
                }
            }
        },
        .TRAIT_UNION(u) => {
            val ms = copy this.ui(u).members;
            for (m&) in ms.items() {
                if (try this.needs_drop(*m)) {
                    r = true;
                }
            }
        },
        .FRAME(i) => { r = true; }, // an unfinished frame is cancelled; a finished one may hold its result
        default => {},
    }
    return r;
}

// an attached delete(this: T&), copy(this: T&) -> T or as_str(this: T&) -> str for this exact type
// (the fn instance, memoized in hook_memo with -1 for none)
attach fn hook(this: checker&, t: u32, name: str) -> compile_error!(u32?) {
    var k = S(name);
    k.push(':');
    k.append_uint(@cast<u64>(t));
    val have = this.hook_memo.get(k.as_str());
    if (have) {
        if (*have < 0) {
            return null;
        }
        return @cast<u32>(*have);
    }
    val key = this.intern(move k);
    this.hook_memo.put(key, -1);
    val found = this.hook_search(t, name) catch |e| {
        // not an answer: the next function to ask (the run goes on after an error) tries again
        this.hook_memo.remove(key);
        return copy e;
    };
    if (found) {
        this.hook_memo.put(key, @cast<i64>(found));
        // copying or printing a val calls these on it (lends.volt)
        if (name == "copy" || name == "as_str") {
            put(&this.ro_hooks, found);
        }
    }
    return found;
}

// hook without the memo
attach fn hook_search(this: checker&, t: u32, name: str) -> compile_error!(u32?) {
    val rt = this.t.ref_to(t);
    var recv = vpure(rt, this.ir.zero(rt));
    var found: u32? = null;
    val none_g: std::vec<garg> = {};
    var none_a: std::vec<tval?> = {};
    if (name == "write_str") {
        put(&none_a, vpure(STR, this.ir.zero(STR))); // write_str takes the text too
    }
    for (d&) in this.named(&this.attached, name).items() {
        val b = try this.bind_cand(*d, &recv, null, &none_g, &none_a);
        match (b) {
            .OK(binds, a) => {
                if (a != adj::NONE) {
                    continue;
                }
                val i = try this.fn_inst(*d, copy binds, {});
                val writes = this.fi(i).ret == VOID && this.fi(i).params.len == 2 && this.fi(i).params.at(1).ty == STR;
                var yields = this.t.opt_inner(this.fi(i).ret) != null;
                match (*this.t.get(this.fi(i).ret)) {
                    .PTR(x) => { yields = true; },
                    default => {},
                }
                if ((name == "copy" && this.fi(i).ret != t) || (name == "as_str" && this.fi(i).ret != STR) || (name == "write_str" && !writes) || (name == "next" && !yields)) {
                    continue;
                }
                found = i;
                break;
            },
            default => {},
        }
    }
    return found;
}

// a glue function (static, void or T, one pointer parameter)
attach fn new_glue(this: checker&, name: str, t: u32, ret: u32) -> u32 {
    var irf: ir_fn = { name: name, params: {}, ret: ret, link: linkage::STATIC, used: true };
    put(&irf.locals, { name: "p", ty: this.t.ref_to(t) });
    put(&irf.params, 0);
    put(&this.ir.fns, bx(move irf));
    val f = @cast<u32>(this.ir.fns.len - 1);
    put(&this.ir.order, f);
    return f;
}

// a new local in glue fn f
attach fn glue_local(this: checker&, f: u32, name: str, t: u32) -> local_ref {
    val fp = this.ir.fn_at(f);
    put(&fp.locals, { name: name, ty: t });
    val id = @cast<u32>(fp.locals.len - 1);
    return { id: id, c: this.ir.node(ir_kind::LOCAL(id), t) };
}

// the fn that deletes a value in place: void f(T*)
// (made once per type. A struct drops an @owns pointee, then runs its delete hook, then drops its fields
// in reverse)
attach fn drop_fn(this: checker&, t: u32) -> compile_error!u32 {
    var k = S("d");
    k.append_uint(@cast<u64>(t));
    val have = this.glue_names.get(k.as_str());
    if (have) {
        return *have;
    }
    var n = S("volt_drop_");
    n.append_uint(@cast<u64>(t));
    val f = this.new_glue(this.intern(move n), t, VOID);
    this.glue_names.put(this.intern(move k), f);
    if (this.opts.line_info) {
        this.ir.fn_at(f).about = this.intern(fmt("drop {}", this.ty_name(t))); // bolt hot's name for it
    }
    val p = this.ir.node(ir_kind::LOCAL(0), this.t.ref_to(t));
    val obj = this.ir.deref(p, t);
    var body: std::vec<u32> = {};
    match (*this.t.get(t)) {
        .STRUCT(s) => {
            val own = this.owner(t);
            if (own) {
                val o = own;
                if (try this.needs_drop(o.inner)) {
                    val d = try this.drop_fn(o.inner);
                    put(&body, this.call_fn(d, nodes(this.ir.field(obj, o.index, this.t.ref_to(o.inner))), VOID));
                }
            }
            val h = try this.hook(t, "delete");
            if (h) {
                this.use_fn(h);
                put(&body, this.call_fn(this.fi(h).ir, nodes(p), VOID));
            }
            val nf = (try this.struct_fields(s, {})).len;
            var i = nf;
            while (i > 0) {
                i -= 1;
                val ft = (try this.struct_fields(s, {})).at(i).ty;
                if (try this.needs_drop(ft)) {
                    val d = try this.drop_fn(ft);
                    put(&body, this.call_fn(d, nodes(this.ir.addr(this.ir.field(obj, @cast<u32>(i), ft), this.t.ref_to(ft))), VOID));
                }
            }
        },
        .ENUM(e) => {
            val h = try this.hook(t, "delete");
            if (h) {
                this.use_fn(h);
                put(&body, this.call_fn(this.fi(h).ir, nodes(p), VOID));
            }
            val ps = copy *(try this.enum_payloads(e, {}));
            var cases: std::vec<case_arm> = {};
            for (i) in 0..ps.len {
                val pt = *ps.at(i);
                if (pt != null && (try this.needs_drop(pt ?? 0))) {
                    val d = try this.drop_fn(pt ?? 0);
                    val place = this.ir.field(obj, @cast<u32>(i) + 1, pt ?? 0);
                    put(&cases, { value: *this.ei(e).values.at(i), body: this.call_fn(d, nodes(this.ir.addr(place, this.t.ref_to(pt ?? 0))), VOID) });
                }
            }
            if (cases.len > 0) {
                put(&body, this.ir.node(ir_kind::SWITCH(this.tag_of(e, obj), move cases, null), VOID));
            }
        },
        .TUPLE(ts, names) => {
            val xs = copy ts;
            var i = xs.len;
            while (i > 0) {
                i -= 1;
                val et = *xs.at(i);
                if (try this.needs_drop(et)) {
                    val d = try this.drop_fn(et);
                    put(&body, this.call_fn(d, nodes(this.ir.addr(this.ir.field(obj, @cast<u32>(i), et), this.t.ref_to(et))), VOID));
                }
            }
        },
        .CLOSURE(c) => {
            val caps = copy this.ci(c).caps;
            var i = caps.len;
            while (i > 0) {
                i -= 1;
                val ct = caps.at(i).ty;
                if (try this.needs_drop(ct)) {
                    val d = try this.drop_fn(ct);
                    put(&body, this.call_fn(d, nodes(this.ir.addr(this.ir.field(obj, @cast<u32>(i), ct), this.t.ref_to(ct))), VOID));
                }
            }
        },
        .ARRAY(et, n) => {
            val d = try this.drop_fn(et);
            val i = this.glue_local(f, "i", USIZE);
            val end = this.ir.label();
            var inner: std::vec<u32> = {};
            put(&inner, this.ir.if_(this.ir.binary(binop_ir::EQ, i.c, this.ir.int(0, USIZE), BOOL), this.ir.goto_(end), null));
            put(&inner, this.ir.assign(i.c, this.ir.binary(binop_ir::SUB, i.c, this.ir.int(1, USIZE), USIZE)));
            put(&inner, this.call_fn(d, nodes(this.ir.addr(this.ir.index(obj, i.c, et), this.t.ref_to(et))), VOID));
            put(&body, this.ir.decl(i.id, this.ir.int(@cast<i128>(n), USIZE)));
            put(&body, this.ir.node(ir_kind::LOOP(this.ir.block(move inner)), VOID));
            put(&body, this.ir.label_at(end));
        },
        .OPT(x) => {
            val d = try this.drop_fn(x);
            val p = this.opt_parts(t, obj);
            put(&body, this.ir.if_(p.has, this.call_fn(d, nodes(this.ir.addr(p.value, this.t.ref_to(x))), VOID), null));
        },
        .ERR_UNION(e, x) => {
            val code = this.eu_code(t, obj);
            val ct = this.ir.ty_of(code);
            if (try this.needs_drop(x)) {
                val d = try this.drop_fn(x);
                val ok = this.ir.binary(binop_ir::EQ, code, this.ir.int(0, ct), BOOL);
                put(&body, this.ir.if_(ok, this.call_fn(d, nodes(this.ir.addr(this.ir.field(obj, 1, x), this.t.ref_to(x))), VOID), null));
            }
            if (try this.needs_drop(e)) {
                val d = try this.drop_fn(e);
                val bad = this.ir.binary(binop_ir::NE, code, this.ir.int(0, ct), BOOL);
                put(&body, this.ir.if_(bad, this.call_fn(d, nodes(this.ir.addr(this.ir.field(obj, 0, e), this.t.ref_to(e))), VOID), null));
            }
        },
        .TRAIT_UNION(u) => {
            val ms = copy this.ui(u).members;
            var cases: std::vec<case_arm> = {};
            for (i) in 0..ms.len {
                val m = *ms.at(i);
                if (try this.needs_drop(m)) {
                    val d = try this.drop_fn(m);
                    put(&cases, { value: @cast<i128>(i), body: this.call_fn(d, nodes(this.ir.addr(this.ir.field(obj, @cast<u32>(i) + 1, m), this.t.ref_to(m))), VOID) });
                }
            }
            put(&body, this.ir.node(ir_kind::SWITCH(this.ir.field(obj, 0, int_id(int_ty::U16)), move cases, null), VOID));
        },
        .FRAME(i) => {
            // an unfinished frame is stepped once with cancel set, so it runs its own cleanup; a finished
            // one holds its result (frame fields: 0 state, 1 cancel, 2 result)
            val step = this.async_step_fn(i);
            val rt = this.fi(i).ret;
            val state = this.ir.field(obj, 0, U32);
            val live = this.ir.binary(binop_ir::LT, state, this.ir.int(VOLT_DONE, U32), BOOL);
            val cancel = this.ir.block(nodes2(this.ir.assign(this.ir.field(obj, 1, BOOL), this.ir.boolean(true)), this.call_fn(step, nodes(p), BOOL)));
            var els: u32? = null;
            if (try this.needs_drop(rt)) {
                val d = try this.drop_fn(rt);
                val done = this.ir.binary(binop_ir::EQ, state, this.ir.int(VOLT_DONE, U32), BOOL);
                els = this.ir.if_(done, this.call_fn(d, nodes(this.ir.addr(this.ir.field(obj, 2, rt), this.t.ref_to(rt))), VOID), null);
            }
            put(&body, this.ir.if_(live, cancel, els));
        },
        default => {},
    }
    this.ir.fn_at(f).body = this.ir.block(move body);
    put(&this.ir.bodies, f);
    return f;
}

// the fn that deep-copies: T f(T*)
// (made once per type: the copy hook if there is one, else a bitwise copy with each owning part copied
// again. An @owns box without a copy hook can't be copied)
attach fn copy_fn(this: checker&, t: u32, span: span) -> compile_error!u32 {
    var k = S("c");
    k.append_uint(@cast<u64>(t));
    val have = this.glue_names.get(k.as_str());
    if (have) {
        return *have;
    }
    match (*this.t.get(t)) {
        .FRAME(i) => { return fails(span, "a frame can't be copied"); },
        default => {},
    }
    // copying the bytes of something that deletes itself would delete it twice
    if ((try this.hook(t, "copy")) == null && (try this.hook(t, "delete")) != null) {
        return fail(span, fmt("can't copy {}: it attaches delete but not copy, so both copies would delete the same thing; attach fn copy(this: T&) -> T", this.ty_name(t)));
    }
    var n = S("volt_copy_");
    n.append_uint(@cast<u64>(t));
    val f = this.new_glue(this.intern(move n), t, t);
    this.glue_names.put(this.intern(move k), f);
    val p = this.ir.node(ir_kind::LOCAL(0), this.t.ref_to(t));
    val obj = this.ir.deref(p, t);
    val r = this.glue_local(f, "r", t);
    var body: std::vec<u32> = {};
    val h = try this.hook(t, "copy");
    if (h) {
        this.use_fn(h);
        put(&body, this.ir.decl(r.id, this.call_fn(this.fi(h).ir, nodes(p), t)));
    } else {
        put(&body, this.ir.decl(r.id, obj));
        match (*this.t.get(t)) {
            .STRUCT(s) => {
                if (this.box_inner(t) != null) {
                    // an owning pointer's copy needs its allocator, which only the library knows
                    return fail(span, fmt("can't copy {}: attach a copy fn for it: attach fn copy(this: T&) -> T", this.ty_name(t)));
                }
                val nf = (try this.struct_fields(s, span)).len;
                for (i) in 0..nf {
                    val ft = (try this.struct_fields(s, span)).at(i).ty;
                    try this.copy_sub(&body, r.c, obj, @cast<u32>(i), ft, span);
                }
            },
            .TUPLE(ts, names) => {
                val xs = copy ts;
                for (i) in 0..xs.len {
                    try this.copy_sub(&body, r.c, obj, @cast<u32>(i), *xs.at(i), span);
                }
            },
            .CLOSURE(c) => {
                val caps = copy this.ci(c).caps;
                for (i) in 0..caps.len {
                    try this.copy_sub(&body, r.c, obj, @cast<u32>(i), caps.at(i).ty, span);
                }
            },
            .ARRAY(et, n2) => {
                if (try this.needs_drop(et)) {
                    val cf = try this.copy_fn(et, span);
                    val i = this.glue_local(f, "i", USIZE);
                    val src = this.ir.addr(this.ir.index(obj, i.c, et), this.t.ref_to(et));
                    val step = this.ir.assign(this.ir.index(r.c, i.c, et), this.call_fn(cf, nodes(src), et));
                    for (s&) in this.counted_loop(i, this.ir.int(@cast<i128>(n2), USIZE), step).items() {
                        put(&body, *s);
                    }
                }
            },
            .OPT(x) => {
                if (try this.needs_drop(x)) {
                    val cf = try this.copy_fn(x, span);
                    val p = this.opt_parts(t, obj);
                    val src = this.ir.addr(p.value, this.t.ref_to(x));
                    put(&body, this.ir.if_(p.has, this.ir.assign(this.opt_parts(t, r.c).value, this.call_fn(cf, nodes(src), x)), null));
                }
            },
            .ERR_UNION(e, x) => {
                if (try this.needs_drop(x)) {
                    val cf = try this.copy_fn(x, span);
                    val code = this.eu_code(t, obj);
                    val ok = this.ir.binary(binop_ir::EQ, code, this.ir.int(0, this.ir.ty_of(code)), BOOL);
                    val src = this.ir.addr(this.ir.field(obj, 1, x), this.t.ref_to(x));
                    put(&body, this.ir.if_(ok, this.ir.assign(this.ir.field(r.c, 1, x), this.call_fn(cf, nodes(src), x)), null));
                }
                if (try this.needs_drop(e)) {
                    val cf = try this.copy_fn(e, span);
                    val src = this.ir.addr(this.ir.field(obj, 0, e), this.t.ref_to(e));
                    put(&body, this.ir.if_(this.nonzero(this.eu_code(t, obj)), this.ir.assign(this.ir.field(r.c, 0, e), this.call_fn(cf, nodes(src), e)), null));
                }
            },
            .ENUM(e) => {
                val ps = copy *(try this.enum_payloads(e, span));
                var cases: std::vec<case_arm> = {};
                for (i) in 0..ps.len {
                    val pt = *ps.at(i);
                    if (pt != null && (try this.needs_drop(pt ?? 0))) {
                        val x = pt ?? 0;
                        val cf = try this.copy_fn(x, span);
                        val fi = @cast<u32>(i) + 1;
                        val src = this.ir.addr(this.ir.field(obj, fi, x), this.t.ref_to(x));
                        put(&cases, { value: *this.ei(e).values.at(i), body: this.ir.assign(this.ir.field(r.c, fi, x), this.call_fn(cf, nodes(src), x)) });
                    }
                }
                put(&body, this.ir.node(ir_kind::SWITCH(this.tag_of(e, obj), move cases, null), VOID));
            },
            .TRAIT_UNION(u) => {
                val ms = copy this.ui(u).members;
                var cases: std::vec<case_arm> = {};
                for (i) in 0..ms.len {
                    val m = *ms.at(i);
                    if (try this.needs_drop(m)) {
                        val cf = try this.copy_fn(m, span);
                        val fi = @cast<u32>(i) + 1;
                        val src = this.ir.addr(this.ir.field(obj, fi, m), this.t.ref_to(m));
                        put(&cases, { value: @cast<i128>(i), body: this.ir.assign(this.ir.field(r.c, fi, m), this.call_fn(cf, nodes(src), m)) });
                    }
                }
                put(&body, this.ir.node(ir_kind::SWITCH(this.ir.field(obj, 0, int_id(int_ty::U16)), move cases, null), VOID));
            },
            default => {},
        }
    }
    put(&body, this.ir.ret(r.c));
    this.ir.fn_at(f).body = this.ir.block(move body);
    put(&this.ir.bodies, f);
    return f;
}

// r.i = copy(&p->i) when that part owns something
attach fn copy_sub(this: checker&, body: std::vec<u32>&, r: u32, obj: u32, i: u32, t: u32, span: span) -> compile_error!void {
    if (try this.needs_drop(t)) {
        val cf = try this.copy_fn(t, span);
        val src = this.ir.addr(this.ir.field(obj, i, t), this.t.ref_to(t));
        put(body, this.ir.assign(this.ir.field(r, i, t), this.call_fn(cf, nodes(src), t)));
    }
}

// Use a value by value (let, assignment, argument, return, literal member...). An owned local of a
// type that needs delete is moved: its flag clears so its scope won't delete it.
attach fn take(this: checker&, v: tval, span: span) -> compile_error!tval {
    if (!v.lv || !(try this.needs_drop(v.ty))) {
        return v;
    }
    match (*this.t.get(v.ty)) {
        .FRAME(x) => { return fails(span, "a frame can't move (it may point into itself); resume or await it where it is"); },
        default => {},
    }
    val name = v.owner ?? return fail(span, fmt("can't move a {} out of a field, element or reference; copy it instead: copy x", this.ty_name(v.ty)));
    val l = this.lookup_local(name) ?? return fails(span, "");
    val loops_now = this.loops_around();
    if (l.loops < loops_now && this.cx.exiting == 0 && !(this.cx.reassigning != null && (this.cx.reassigning ?? 0) == l.c)) {
        return fail(span, fmt("can't move '{}' inside a loop (the next time around it would already be gone); move it before the loop, or return/break right after", S(name)));
    }
    this.cx.moved.add(l.c);
    this.cx.move_sites.put(l.c, span);
    val flag = l.flag ?? return fails(span, "");
    var r = v;
    r.c = this.ir.seq(nodes(this.ir.assign(flag, this.ir.boolean(false))), v.c, v.ty);
    r.lv = false;
    r.pure = false;
    r.owner = null;
    r.mutable = false;
    return r;
}

// take(v) then convert to `to`; a box handed to a T& or T* is only borrowed, not moved
attach fn take_into(this: checker&, v: tval, to: u32, span: span) -> compile_error!tval {
    val target = this.pointee(to);
    var borrow = false;
    if (target) {
        val bi = this.box_inner(v.ty);
        borrow = bi != null && (bi ?? 0) == target;
    }
    var x = v;
    if (!borrow) {
        x = try this.take(v, span);
    }
    return this.coerce(x, to, span);
}

// a copy of v the caller owns: v itself when nothing needs deleting or it's a temporary, else a deep copy
attach fn copy_val(this: checker&, v: tval, span: span) -> compile_error!tval {
    if (!(try this.needs_drop(v.ty))) {
        var r = v;
        r.owner = null;
        return r;
    }
    if (!v.lv) {
        return v; // a temporary is already a fresh value
    }
    val f = try this.copy_fn(v.ty, span);
    return vnew(v.ty, this.call_fn(f, nodes(this.ir.addr(v.c, this.t.ref_to(v.ty))), v.ty));
}

struct owned {
    c: u32;
    flag: u32?; // the statement declaring its live flag
}

// declare an owned local; returns its place and the statement declaring its live flag
attach fn owned_local(this: checker&, name: str, t: u32, mutable: bool) -> compile_error!owned {
    val c = this.new_local(name, t, mutable);
    if (!(try this.needs_drop(t))) {
        return { c: c, flag: null };
    }
    val flag = this.flag_for(c);
    val d = try this.drop_fn(t);
    val s = this.scope_top();
    val l = s.vars.get(name) ?? return fails({}, "");
    l.flag = flag;
    put(&s.exits, exit::DROP(c, d, flag));
    return { c: c, flag: this.decl_at(flag, this.ir.boolean(true)) };
}

// a statement's discarded value: delete it if it's a temporary that owns something
attach fn discard(this: checker&, v: tval) -> compile_error!u32 {
    if (v.ty == VOID || v.ty == NEVER || v.lv || !(try this.needs_drop(v.ty))) {
        return v.c;
    }
    val d = try this.drop_fn(v.ty);
    val t = this.tmp_local("d", v.ty);
    val call = this.call_fn(d, nodes(this.ir.addr(t.c, this.t.ref_to(v.ty))), VOID);
    return this.ir.seq(nodes2(this.ir.decl(t.id, v.c), call), null, VOID);
}

// ---------- slots: locals that may live across a suspend ----------

// a place for a local: a frame field inside an async fn, a local otherwise
attach fn field_c(this: checker&, name: str, t: u32) -> u32 {
    val fr = this.cx.frame;
    if (fr) {
        val ff = this.frame_of(fr);
        put(&ff.fields, { name: name, ty: t });
        val i = @cast<u32>(ff.fields.len - 1);
        val ft = this.t.intern(tyk::FRAME(fr));
        return this.ir.field(this.ir.deref(this.cx.frame_ptr, ft), 3 + i, t);
    }
    return this.new_ir_local(name, t).c;
}

// a fresh statement-level variable that may live across a suspend (name_7)
attach fn slot(this: checker&, base: str, t: u32) -> u32 {
    this.cx.next_id += 1;
    // a hidden local's Volt name starts with @ (no source can name it); its C name drops that
    var n = S(base);
    if (base.len > 0 && base[0] == '@') {
        n = S(base[1..]);
    }
    // frame fields share one struct, so they need unique names; the C backend makes locals' names unique
    if (this.cx.frame != null) {
        n.push('_');
        n.append_uint(@cast<u64>(this.cx.next_id));
    }
    return this.field_c(this.intern(move n), t);
}

// the "still live" flag of an owned local
attach fn flag_for(this: checker&, c: u32) -> u32 {
    var n = S(this.place_name(c));
    n.append("_live");
    return this.field_c(this.intern(move n), BOOL);
}

// the name of a local or frame slot
attach fn place_name(this: checker&, c: u32) -> str {
    match (this.ir.at(c).kind) {
        .LOCAL(id) => { return this.ir.fn_at(this.cx.irf).locals.at(@cast<usize>(id)).name; },
        .FIELD(base, i) => {
            val fr = this.cx.frame;
            if (fr != null && i >= 3) {
                return this.frame_of(fr ?? 0).fields.at(@cast<usize>(i - 3)).name;
            }
        },
        default => {},
    }
    return "x";
}

// the frame record of async fn instance idx, made on first use
attach fn frame_of(this: checker&, idx: u32) -> fn_frame& {
    for (f&) in this.frames.items() {
        if (f.fn_idx == idx) {
            return f;
        }
    }
    put(&this.frames, { fn_idx: idx });
    return this.frames.at(this.frames.len - 1);
}
