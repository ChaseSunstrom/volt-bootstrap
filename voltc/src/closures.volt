// Closures: a port of bootstrap/check/closures.rs. Each closure literal is a struct of its captures (its
// own type) with its own function, so generics call it directly. fn(A) -> R is a fat {fn, env} pair
// that borrows a closure or wraps a plain function; nothing is allocated.
// A generic closure (`|caps| <T: type>(x: T) -> T { ... }`) takes its captures once; each call infers
// its generic args from the arguments' types and gets an instance of the body for them (an entry of its
// own in `closures`, made once per args), like a generic fn.
use std::mem;

// how a capture appears inside the closure body
struct cap_inner {
    name: str;
    ty: u32;      // its type inside the body
    by_ref: bool; // stored as a T&
    mutable: bool;
    outer: local = { c: 0, ty: 0, mutable: false }; // the captured local (lends.volt)
}

// a generic closure literal, checked per instance
struct generic_closure {
    ast: closure&;
    gps: std::vec<gparam>;
    env: u32;
    inner: std::vec<cap_inner>;
    maker: u64?; // the body the literal is in (its captures may reach through that body's parameters)
    span: span;
    insts: std::vec<closure_inst> = {};
}

// an instance of a generic closure: its generic args (types), and its closure
struct closure_inst {
    args: std::vec<u32>;
    id: u32;
}

attach fn gc(this: checker&, i: u32) -> generic_closure& {
    return *this.gclosures.at(@cast<usize>(i));
}

// a closure literal: makes its body fn (env: closure&) and an erased twin (env: void*) that forwards to it,
// and returns the capture struct's value. Untyped params and the return type come from `want` when it is a
// fn(...) type
attach fn closure_expr(this: checker&, cl: closure&, want: u32?, span: span) -> compile_error!tval {
    val env = this.cx.env;
    var gps: std::vec<gparam> = {};
    for (g&) in cl.generics.items() {
        val gp = gparam_of(g);
        var is_type = !gp.pack;
        if (is_type) {
            match (try this.param_kind(&gp, env)) {
                .TYPE => {},
                default => { is_type = false; },
            }
        }
        if (!is_type) {
            return fails(g.span, "a closure's generic parameters are types: <T: type>");
        }
        put(&gps, move gp);
    }
    var want_ps: std::vec<u32>? = null;
    var want_r: u32 = VOID;
    if (want) {
        match (*this.t.get(want)) {
            .FN_VAL(ps, r) => {
                want_ps = copy ps;
                want_r = r;
            },
            default => {},
        }
    }
    if (want_ps != null && want_ps.value.len != cl.params.len) {
        return fail(span, fmt2("expected a closure taking {} parameters, this one takes {}", unum(@cast<u64>(want_ps.value.len)), unum(@cast<u64>(cl.params.len))));
    }
    // a generic closure's types are known per instance
    var ptys: std::vec<u32> = {};
    var rty = VOID;
    if (gps.len == 0) {
        for (i) in 0..cl.params.len {
            val p = cl.params.at(i);
            if (p.ty) {
                put(&ptys, try this.resolve_type(&p.ty, env));
            } else if (want_ps) {
                put(&ptys, *want_ps.at(i));
            } else {
                return fails(p.span, "closure parameter needs a type here: (x: i32)");
            }
        }
        if (cl.ret) {
            rty = try this.resolve_type(&cl.ret, env);
        } else if (want_ps) {
            rty = want_r;
        }
    }
    // captures: the stored field, its initializer, and how the body sees it
    var stored: std::vec<cap_field> = {};
    var inits: std::vec<field_init> = {};
    var inner: std::vec<cap_inner> = {};
    for (c&) in cl.caps.items() {
        val l = this.lookup_local(c.name) ?? return fail(c.span, fmt("no local '{}' to capture", S(c.name)));
        if (this.cx.moved.has(l.c)) {
            val e = fail(c.span, fmt("'{}' was moved earlier, so it can't be captured", S(c.name)));
            val at = this.cx.move_sites.get(l.c);
            if (at) {
                return with_label(move e, *at, S("moved here"));
            }
            return move e;
        }
        var v = vpure(l.ty, l.c);
        v.lv = true;
        v.mutable = l.mutable;
        v.own = l.own;
        if (l.flag != null) {
            v.owner = c.name;
        }
        val i = @cast<u32>(stored.len);
        if (c.mode == cap_mode::REF) {
            val rt = this.t.ref_to(l.ty);
            put(&stored, { name: c.name, ty: rt });
            put(&inits, { field: i, value: this.ir.addr(l.c, rt) });
            this.note_mut(&v); // changed through the capture, maybe
            put(&inner, { name: c.name, ty: l.ty, by_ref: true, mutable: l.mutable, outer: l });
        } else {
            var x = vnew(0, 0);
            if (c.mode == cap_mode::MOVE) {
                x = try this.take(v, c.span);
            } else {
                x = try this.copy_val(v, c.span);
            }
            put(&stored, { name: c.name, ty: l.ty });
            put(&inits, { field: i, value: x.c });
            put(&inner, { name: c.name, ty: l.ty, by_ref: false, mutable: true, outer: l });
        }
    }
    // the closure's own type
    val id = @cast<u32>(this.closures.len);
    val c_name = this.fresh_c_name("volt_closure");
    val ty = this.t.intern(tyk::CLOSURE(id));
    var names: std::vec<str> = {};
    for (p&) in cl.params.items() {
        put(&names, p.name);
    }
    for (c&) in inner.items() {
        put(&names, c.name);
    }
    put(&this.closures, bx<closure_info>({ c_name: c_name, fn_ir: 0, erased_ir: 0, caps: move stored, params: move ptys, ret: rty, names: move names }));
    if (gps.len > 0) {
        this.ci(id).gen = @cast<u32>(this.gclosures.len);
        put(&this.gclosures, bx<generic_closure>({ ast: cl, gps: move gps, env: env, inner: move inner, maker: this.cx.body, span: span }));
    } else {
        try this.closure_fns(id, ty, cl, &inner, env, this.cx.body, null, span);
    }
    return vnew(ty, this.ir.node(ir_kind::AGG(move inits), ty));
}

// makes closure id's two functions (closure type ty, whose captures are inner): the body, checked in env,
// and the erased one that forwards to it. A generic closure's instance n gets names of its own
attach fn closure_fns(this: checker&, id: u32, ty: u32, cl: closure&, inner: std::vec<cap_inner>&, env: u32, maker: u64?, n: u32?, span: span) -> compile_error!void {
    val rt = this.t.ref_to(ty);
    val ptys = copy this.ci(id).params;
    val rty = this.ci(id).ret;
    // R f(closure& env, params...) and R f(void* env, params...)
    var fn_name = S(this.ci(id).c_name);
    fn_name.append("_fn");
    var erased_name = S(this.ci(id).c_name);
    erased_name.append("_erased");
    if (n) {
        fn_name.append_uint(@cast<u64>(n));
        erased_name.append_uint(@cast<u64>(n));
    }
    var fir: ir_fn = { name: this.intern(move fn_name), params: {}, ret: rty, link: linkage::STATIC, used: true, noreturn: rty == NEVER, origin: span, about: "a closure" };
    var eir: ir_fn = { name: this.intern(move erased_name), params: {}, ret: rty, link: linkage::STATIC, used: true, noreturn: rty == NEVER, origin: span, about: "a closure, called through a fn value" };
    put(&fir.locals, { name: "env", ty: rt });
    put(&fir.params, 0);
    put(&eir.locals, { name: "env", ty: VOIDPTR });
    put(&eir.params, 0);
    for (i) in 0..cl.params.len {
        var pn = S(cl.params.at(i).name);
        pn.push('_');
        pn.append_uint(@cast<u64>(i));
        val ln = this.intern(move pn);
        put(&fir.locals, { name: ln, ty: *ptys.at(i) });
        put(&fir.params, @cast<u32>(fir.locals.len - 1));
        put(&eir.locals, { name: ln, ty: *ptys.at(i) });
        put(&eir.params, @cast<u32>(eir.locals.len - 1));
    }
    put(&this.ir.fns, bx(move fir));
    val fi = @cast<u32>(this.ir.fns.len - 1);
    put(&this.ir.fns, bx(move eir));
    val ei = @cast<u32>(this.ir.fns.len - 1);
    put(&this.ir.order, fi);
    put(&this.ir.order, ei);
    this.ci(id).fn_ir = fi;
    this.ci(id).erased_ir = ei;
    // a captured reference reaching through one of ours is passed on to the closure
    for (ci) in 0..inner.len {
        val c = inner.at(ci);
        val ov = c.outer.via;
        if (ov) {
            // a parameter of the body the literal is in, or a call's result
            var from = maker;
            if (ov.k >= SITE) {
                from = body_key(BODY_SITE, ov.k - SITE);
            }
            if (from != null && this.reaches(c.ty)) {
                put(&this.lend_edges, { from: from ?? 0, k: via_param(ov.k), off: ov.off, to: body_key(BODY_CLOSURE, id), j: cl.params.len + ci });
            }
        }
    }

    // the body is its own function; it sees its captures and params, not the outer locals
    var saved = new_cx(rty, env, fi);
    saved.body = body_key(BODY_CLOSURE, id);
    swap(&saved, &this.cx);
    val r = this.closure_body(cl, inner, &ptys, rty, ty);
    swap(&saved, &this.cx);
    val body = try r;
    this.ir.fn_at(fi).body = body;
    put(&this.ir.bodies, fi);

    // the erased one forwards to it
    var args = nodes(this.ir.conv(this.ir.node(ir_kind::LOCAL(0), VOIDPTR), rt));
    for (i) in 0..ptys.len {
        put(&args, this.ir.node(ir_kind::LOCAL(@cast<u32>(i) + 1), *ptys.at(i)));
    }
    val call = this.call_fn(fi, move args, rty);
    if (rty == VOID || rty == NEVER) {
        this.ir.fn_at(ei).body = this.ir.block(nodes(call));
    } else {
        this.ir.fn_at(ei).body = this.ir.block(nodes(this.ir.ret(call)));
    }
    put(&this.ir.bodies, ei);
}

// what an argument for generic closure id's parameter i is checked against: the parameter's type when it
// doesn't name the closure's generics (an i32 param takes a literal as an i32)
attach fn generic_closure_want(this: checker&, id: u32, i: usize) -> u32? {
    val gi = this.ci(id).gen ?? return null;
    val g = this.gc(gi);
    if (i >= g.ast.params.len) {
        return null;
    }
    val p = g.ast.params.at(i);
    if (p.ty) {
        // the closure's generics bound to values, so a type naming one doesn't resolve
        var e: env = { ns: this.env_at(g.env).ns };
        for (b&) in this.env_at(g.env).generics.items() {
            put(&e.generics, copy *b);
        }
        for (gp&) in g.gps.items() {
            put(&e.generics, { name: gp.name, g: gval::INT(0) });
        }
        val ne = this.new_env(move e);
        val t = this.resolve_type(&p.ty, ne) catch |x| { return null; };
        return t;
    }
    return null;
}

// generic closure id's instance for arguments of these types: its generic args are inferred from them,
// and the body is checked and made the first time
attach fn closure_instance(this: checker&, id: u32, args: std::vec<u32>&, span: span) -> compile_error!u32 {
    val gi = this.ci(id).gen ?? @panic("a generic closure");
    val g = this.gc(gi);
    if (args.len != g.ast.params.len) {
        return fail(span, fmt2("expected {} arguments, found {}", unum(@cast<u64>(g.ast.params.len)), unum(@cast<u64>(args.len))));
    }
    val ns = this.env_at(g.env).ns;
    var binds: std::vec<gval?> = {};
    for (i) in 0..g.gps.len {
        put(&binds, null);
    }
    for (i) in 0..args.len {
        val p = g.ast.params.at(i);
        if (p.ty) {
            this.infer(&p.ty, *args.at(i), &g.gps, &binds, ns);
        }
    }
    var tys: std::vec<u32> = {};
    for (i) in 0..g.gps.len {
        val b = *binds.at(i) ?? return fail(span, fmt("can't tell what '{}' is from this call's arguments", S(g.gps.at(i).name)));
        match (b) {
            .TY(t) => { put(&tys, t); },
            default => { return fail(span, fmt("can't tell what '{}' is from this call's arguments", S(g.gps.at(i).name))); },
        }
    }
    for (x&) in g.insts.items() {
        if (same_list(&x.args, &tys)) {
            return x.id;
        }
    }
    var gv: std::vec<gval> = {};
    for (t&) in tys.items() {
        put(&gv, gval::TY(*t));
    }
    val bad = try this.check_bounds(&g.gps, &gv, ns);
    if (bad) {
        return fail(span, copy bad);
    }
    var e: env = { ns: ns };
    for (b&) in this.env_at(g.env).generics.items() {
        put(&e.generics, copy *b);
    }
    for (i) in 0..g.gps.len {
        put(&e.generics, { name: g.gps.at(i).name, g: *gv.at(i) });
    }
    val ie = this.new_env(move e);
    var ptys: std::vec<u32> = {};
    for (p&) in g.ast.params.items() {
        if (p.ty) {
            put(&ptys, try this.resolve_type(&p.ty, ie));
        } else {
            return fails(p.span, "a generic closure's parameters need types: (x: T)");
        }
    }
    var rty = VOID;
    if (g.ast.ret) {
        rty = try this.resolve_type(&g.ast.ret, ie);
    }
    val inst = @cast<u32>(this.closures.len);
    val base = this.ci(id);
    put(&this.closures, bx<closure_info>({ c_name: base.c_name, fn_ir: 0, erased_ir: 0, caps: copy base.caps, params: move ptys, ret: rty, names: copy base.names }));
    val n = @cast<u32>(g.insts.len);
    put(&g.insts, { args: move tys, id: inst });
    try this.closure_fns(inst, this.t.intern(tyk::CLOSURE(id)), g.ast, &g.inner, ie, g.maker, n, g.span);
    return inst;
}

// does t, a generic closure, take n parameters?
attach fn generic_closure_takes(this: checker&, t: u32, n: usize) -> bool {
    match (*this.t.get(t)) {
        .CLOSURE(id) => {
            val gi = this.ci(id).gen ?? return false;
            return this.gc(gi).ast.params.len == n;
        },
        default => { return false; },
    }
}

// checks the body in the closure's own cx: captures are fields of *env (deref'd again for `&` captures)
// and params are locals 1..n; returns the IR block
attach fn closure_body(this: checker&, cl: closure&, inner: std::vec<cap_inner>&, ptys: std::vec<u32>&, rty: u32, ty: u32) -> compile_error!u32 {
    val envp = this.ir.node(ir_kind::LOCAL(0), this.t.ref_to(ty));
    val obj = this.ir.deref(envp, ty);
    for (i) in 0..inner.len {
        val c = inner.at(i);
        var place: u32 = 0;
        if (c.by_ref) {
            place = this.ir.deref(this.ir.field(obj, @cast<u32>(i), this.t.ref_to(c.ty)), c.ty);
        } else {
            place = this.ir.field(obj, @cast<u32>(i), c.ty);
        }
        var l: local = { c: place, ty: c.ty, mutable: c.mutable, ro: c.outer.ro, root: c.name, param: c.outer.param };
        if (this.reaches(c.ty)) {
            val rv: reach = { k: @cast<u32>(cl.params.len + i), off: 0 };
            l.via = rv;
        }
        this.cx.scopes.at(0).vars.put(c.name, l);
    }
    var stmts: std::vec<u32> = {};
    for (i) in 0..cl.params.len {
        val p = cl.params.at(i);
        val t = *ptys.at(i);
        val c = this.ir.node(ir_kind::LOCAL(@cast<u32>(i) + 1), t);
        var l: local = { c: c, ty: t, mutable: p.mutable, root: p.name, param: true, own: c };
        if (this.opts.lsp) {
            this.lsp_add_local(c, p.name, t, this.name_span(p.span, p.name), p.mutable, true);
        }
        if (this.reaches(t)) {
            val rv: reach = { k: @cast<u32>(i), off: 0 };
            l.via = rv;
        }
        if (try this.needs_drop(t)) {
            val flag = this.flag_for(c);
            put(&stmts, this.decl_at(flag, this.ir.boolean(true)));
            val d = try this.drop_fn(t);
            put(&this.cx.scopes.at(0).exits, exit::DROP(c, d, flag));
            l.flag = flag;
        }
        this.cx.scopes.at(0).vars.put(p.name, l);
    }
    val code = try this.block_code(&cl.body);
    if (!code.div && rty != VOID) {
        return fail(cl.body.span, fmt("this closure can reach its end without returning a {}", this.ty_name(rty)));
    }
    put(&stmts, code.c);
    if (!code.div) {
        for (x&) in (try this.scope_exit_code(0, 0, false)).items() {
            put(&stmts, *x);
        }
    }
    return this.ir.block(move stmts);
}

// a plain function as a fn(...) value: {trampoline, null}
// (the trampoline is made once per fn instance, keyed "t<inst>" in glue_names, and ignores env)
attach fn fn_value(this: checker&, inst: u32, fv: u32) -> u32 {
    var k = S("t");
    k.append_uint(@cast<u64>(inst));
    var tramp: u32 = 0;
    val have = this.glue_names.get(k.as_str());
    if (have) {
        tramp = *have;
    } else {
        val f = this.fi(inst);
        val target = f.ir;
        val ret = f.ret;
        var name = S(f.c_name);
        name.append("_tramp");
        var irf: ir_fn = { name: this.intern(move name), params: {}, ret: ret, link: linkage::STATIC, used: true, noreturn: ret == NEVER, origin: this.item_of(f.decl).span, about: f.name };
        put(&irf.locals, { name: "env", ty: VOIDPTR });
        put(&irf.params, 0);
        var args: std::vec<u32> = {};
        for (i) in 0..f.params.len {
            val p = f.params.at(i);
            if (p.is_comptime || p.ty == VOID) {
                continue;
            }
            var an = S("a");
            an.append_uint(@cast<u64>(i));
            put(&irf.locals, { name: this.intern(move an), ty: p.ty });
            val li = @cast<u32>(irf.locals.len - 1);
            put(&irf.params, li);
            put(&args, this.ir.node(ir_kind::LOCAL(li), p.ty));
        }
        put(&this.ir.fns, bx(move irf));
        tramp = @cast<u32>(this.ir.fns.len - 1);
        this.glue_names.put(this.intern(move k), tramp);
        put(&this.ir.order, tramp);
        this.use_fn(inst);
        val call = this.call_fn(target, move args, ret);
        if (ret == VOID || ret == NEVER) {
            this.ir.fn_at(tramp).body = this.ir.block(nodes(call));
        } else {
            this.ir.fn_at(tramp).body = this.ir.block(nodes(this.ir.ret(call)));
        }
        put(&this.ir.bodies, tramp);
    }
    var inits: std::vec<field_init> = {};
    put(&inits, { field: 0, value: this.ir.node(ir_kind::FN(tramp), VOIDPTR) });
    put(&inits, { field: 1, value: this.ir.node(ir_kind::NULLPTR, VOIDPTR) });
    return this.ir.node(ir_kind::AGG(move inits), fv);
}

// closure -> fn(...) value: borrows the closure's storage; id is the closure, or the generic closure's
// instance the value calls
attach fn closure_to_fn(this: checker&, v: tval&, fv: u32, id: u32) -> u32 {
    this.escape(body_key(BODY_CLOSURE, id), fv);
    // a closure literal gets storage of its own: the fn value points at it for the rest of the fn
    var place = v.c;
    var pre: std::vec<u32> = {};
    if (!v.lv) {
        val t = this.tmp_local("cl", v.ty);
        put(&pre, this.ir.decl(t.id, v.c));
        place = t.c;
    }
    var inits: std::vec<field_init> = {};
    put(&inits, { field: 0, value: this.ir.node(ir_kind::FN(this.ci(id).erased_ir), VOIDPTR) });
    put(&inits, { field: 1, value: this.ir.conv(this.ir.addr(place, this.t.ref_to(v.ty)), VOIDPTR) });
    val agg = this.ir.node(ir_kind::AGG(move inits), fv);
    if (pre.len == 0) {
        return agg;
    }
    return this.ir.seq(move pre, agg, fv);
}

// is t a closure (not a generic one) taking ps and giving r?
attach fn closure_sig_is(this: checker&, t: u32, ps: std::vec<u32>&, r: u32) -> bool {
    match (*this.t.get(t)) {
        .CLOSURE(id) => {
            val c = this.ci(id);
            return c.gen == null && c.ret == r && same_list(&c.params, ps);
        },
        default => { return false; },
    }
}
