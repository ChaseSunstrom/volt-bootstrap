// Calls (direct, through fn values, variadic) and the @builtins.
// A port of bootstrap/check/calls.rs.
use std::mem;

// ---------- calls ----------

// Mark a fn instance used. The first time, its ir fn gets its linkage and a place in the output
// order, and its body is queued for gen_fn (not for an intrinsic, or a fn a linked library defines).
attach fn use_fn(this: checker&, idx: u32) -> void {
    if (*this.used.at(@cast<usize>(idx))) {
        return;
    }
    *this.used.at(@cast<usize>(idx)) = true;
    if (this.fi(idx).intrinsic != null) {
        return; // provided by the prelude
    }
    val irf = this.fi(idx).ir;
    val link = this.fn_linkage(idx);
    val f = this.ir.fn_at(irf);
    f.link = link;
    f.used = true;
    put(&this.ir.order, irf);
    if (this.is_async_fn(idx)) {
        this.async_fns(idx); // its helpers are declared next to it
    }
    val fd = this.fn_decl_of(this.fi(idx).decl);
    var has_body = false;
    if (fd) {
        has_body = (fd).body != null;
    }
    if (has_body && link != linkage::EXTERNAL) {
        put(&this.queue, idx);
    }
}

// `f(args)`: .VARIANT(...), a method call, a named fn (overloads resolved), Type::f() or an enum
// variant; any other callee is a value, called through call_value
attach fn call(this: checker&, callee: expr&, args: std::vec<expr>&, want: u32?, span: span) -> compile_error!tval {
    match (callee.kind) {
        .DOT_VARIANT(n) => { return this.dot_variant(n, args, want, span); },
        .FIELD(base, name, gargs) => {
            val recv = try this.expr(base, null);
            var none: std::vec<garg> = {};
            if (gargs) {
                return this.method_call(recv, name, &gargs, args, want, span);
            }
            return this.method_call(recv, name, &none, args, want, span);
        },
        .PATH(p&) => {
            if (!(p.is_single() && this.lookup_local(p.segs.at(0).name) != null)) {
                val ns = this.env_at(this.cx.env).ns;
                var f: found? = null;
                if (p.segs.len == 1) {
                    f = this.lookup(ns, p.segs.at(0).name);
                } else {
                    f = this.lookup_path_ns(ns, p);
                }
                var explicit: std::vec<garg> = {};
                val last = p.segs.at(p.segs.len - 1);
                val ex = &explicit;
                var exp: std::vec<garg>& = ex;
                if (last.args) {
                    exp = &last.args;
                }
                if (f) {
                    match (f) {
                        .DECLS(l) => {
                            var fns: std::vec<u32> = {};
                            for (d&) in this.list(l).items() {
                                if (this.fn_decl_of(*d) != null) {
                                    put(&fns, *d);
                                }
                            }
                            if (fns.len > 0) {
                                return this.resolve_call(p.last(), &fns, null, null, exp, args, want, span);
                            }
                        },
                        default => {},
                    }
                } else {
                    val m = try this.member_path(p);
                    if (m) {
                        match (m) {
                            .OF(t, mem) => {
                                val eid = this.enum_of(t);
                                if (eid) {
                                    val idx = this.variant_index(eid, mem);
                                    if (idx) {
                                        return this.make_variant(t, idx, args, span);
                                    }
                                }
                                return this.static_call(t, mem, exp, args, want, span);
                            },
                            .GENERIC_ENUM(d, mem) => {
                                val t = try this.infer_enum(d, mem, args, want, span);
                                return this.type_member_value(t, mem, args, span);
                            },
                        }
                    }
                }
            }
        },
        default => {},
    }
    val fv = try this.expr(callee, null);
    return this.call_value(fv, args, span);
}

// call through a value: a C fn pointer, a fn(...) value (its fn and env) or a closure
attach fn call_value(this: checker&, f: tval, args: std::vec<expr>&, span: span) -> compile_error!tval {
    var ps: std::vec<u32> = {};
    var ret: u32 = VOID;
    var va = false;
    var kind = 0;
    var closure: u32 = 0;
    // a generic closure: the arguments' types pick its instance (made the first time)
    var given: std::vec<tval> = {};
    var inst: u32? = null;
    match (*this.t.get(f.ty)) {
        .CLOSURE(c) => {
            if (this.ci(c).gen != null) {
                for (i) in 0..args.len {
                    put(&given, try this.expr(args.at(i), this.generic_closure_want(c, i)));
                }
                var tys: std::vec<u32> = {};
                for (g&) in given.items() {
                    put(&tys, g.ty);
                }
                inst = try this.closure_instance(c, &tys, span);
            }
        },
        default => {},
    }
    match (*this.t.get(f.ty)) {
        .FN_PTR(p, r, v) => {
            ps = copy p;
            ret = r;
            va = v;
            kind = 0;
        },
        .FN_VAL(p, r) => {
            ps = copy p;
            ret = r;
            kind = 1;
        },
        .CLOSURE(c) => {
            closure = inst ?? c;
            ps = copy this.ci(closure).params;
            ret = this.ci(closure).ret;
            kind = 2;
        },
        default => { return fail(span, fmt("can't call a {}", this.ty_name(f.ty))); },
    }
    if (args.len < ps.len || (!va && args.len > ps.len)) {
        return fail(span, fmt2("expected {} arguments, found {}", unum(@cast<u64>(ps.len)), unum(@cast<u64>(args.len))));
    }
    val fty = f.ty;
    // what the call runs: this closure's body, or what any fn of this type made into a value does
    var callee = body_key(BODY_VALUE, this.value_key(fty));
    if (kind == 2) {
        callee = body_key(BODY_CLOSURE, closure);
    }
    val site = this.open_site(callee, ret);
    var vals: std::vec<tval> = {};
    put(&vals, f);
    for (i) in 0..args.len {
        val a = args.at(i);
        if (i < ps.len) {
            val p = *ps.at(i);
            var v = vnew(0, 0);
            if (i < given.len) {
                v = *given.at(i);
            } else {
                v = try this.expr(a, p);
            }
            val tv = try this.take_into(v, p, a.span);
            if (this.holds(p)) {
                this.note_arg(callee, i, &tv, a.span, site);
            }
            put(&vals, tv);
        } else {
            val v = try this.expr(a, null);
            put(&vals, try this.vararg_val(v, a.span));
        }
    }
    val pre = this.seq_vals(&vals);
    var cs: std::vec<u32> = {};
    for (i) in 1..vals.len {
        put(&cs, vals.at(i).c);
    }
    var c: u32 = 0;
    if (kind == 0) {
        c = this.ir.call(vals.at(0).c, move cs, ret);
    } else if (kind == 1) {
        val tf = this.tmp_local("f", fty);
        var all: std::vec<u32> = {};
        put(&all, this.ir.field(tf.c, 1, VOIDPTR));
        for (x&) in cs.items() {
            put(&all, *x);
        }
        val call = this.ir.call(this.ir.field(tf.c, 0, VOIDPTR), move all, ret);
        c = this.ir.seq(nodes(this.ir.decl(tf.id, vals.at(0).c)), call, ret);
        if (ret == VOID || ret == NEVER) {
            c = this.ir.seq(nodes2(this.ir.decl(tf.id, vals.at(0).c), call), null, ret);
        }
    } else {
        val fir = this.ci(closure).fn_ir;
        val pt = this.t.ref_to(fty);
        var all: std::vec<u32> = {};
        if (vals.at(0).lv) {
            put(&all, this.ir.addr(vals.at(0).c, pt));
            for (x&) in cs.items() {
                put(&all, *x);
            }
            c = this.call_fn(fir, move all, ret);
        } else {
            val tcl = this.tmp_local("cl", fty);
            put(&all, this.ir.addr(tcl.c, pt));
            for (x&) in cs.items() {
                put(&all, *x);
            }
            val call = this.call_fn(fir, move all, ret);
            if (ret == VOID || ret == NEVER) {
                c = this.ir.seq(nodes2(this.ir.decl(tcl.id, vals.at(0).c), call), null, ret);
            } else {
                c = this.ir.seq(nodes(this.ir.decl(tcl.id, vals.at(0).c)), call, ret);
            }
        }
    }
    return site_result(vnew(ret, this.wrap_pre(move pre, c, ret)), site);
}

// an argument for C varargs: a str literal becomes a cstr, a float narrower than f64 is promoted
attach fn vararg_val(this: checker&, v: tval, span: span) -> compile_error!tval {
    match (*this.t.get(v.ty)) {
        .STR => {
            if (v.lit != null) {
                return this.coerce(v, CSTR, span);
            }
            return fails(span, "C varargs can't take a str; pass a cstr");
        },
        .FLOAT(b) => {
            if (b < 64) {
                var r = v;
                r.c = this.ir.conv(v.c, F64);
                r.ty = F64;
                r.lit = null;
                return r;
            }
        },
        default => {},
    }
    return v;
}

// ---------- builtins ----------

// a generic arg read as a type in the current fn's env
attach fn garg_type(this: checker&, g: garg&) -> compile_error!u32 {
    return this.garg_type_env(g, this.cx.env);
}

// a builtin's argument checked as an expression
// @field(v, "name"): v's field of that name, worked out at compile time, as the v.name it is (read,
// written, borrowed, narrowed like it)
attach fn field_form(this: checker&, base: garg&, name: garg&, span: span) -> compile_error!expr {
    val b = try this.garg_value(base);
    val n = try this.garg_value(name);
    var fname = S("");
    match (try this.ct_eval(n, null)) {
        .STR(s) => { fname = copy s; },
        // a tuple's element by its index
        .INT(i, t) => {
            if (i < 0) {
                return fails(n.span, "@field(v, \"name\"): the name is a comptime string (or a tuple element's index)");
            }
            fname = num(i);
        },
        default => { return fails(n.span, "@field(v, \"name\"): the name is a comptime string (or a tuple element's index)"); },
    }
    return { kind: expr_kind::FIELD(bx(copy *b), this.intern(move fname), null), span: span };
}

attach fn garg_expr(this: checker&, g: garg&, want: u32?) -> compile_error!tval {
    val e = try this.garg_value(g);
    return this.expr(e, want);
}

// a scalar for @cast: converts as a value, not by reinterpreting bytes
attach fn cast_scalar(this: checker&, t: u32) -> bool {
    match (*this.t.get(t)) {
        .INT(k) => { return true; },
        .FLOAT(b) => { return true; },
        .BOOL => { return true; },
        .REF(x) => { return true; },
        .PTR(x) => { return true; },
        .VOIDPTR => { return true; },
        .CSTR => { return true; },
        .FN_PTR(a, b, c) => { return true; },
        .OPT(i) => { return this.t.is_niche(i); },
        default => { return false; },
    }
}

// The @builtins that generate code: sizeof, alignof, offsetof, cast, write, slice, read, volatile_read,
// volatile_write, typeid, panic.
// The compile-time ones (@typeinfo...) are evaluated by comptime instead.
attach fn builtin(this: checker&, name: str, gargs: std::vec<garg>&, args_opt: std::vec<garg>*, want: u32?, span: span) -> compile_error!tval {
    var none: std::vec<garg> = {};
    var args: std::vec<garg>& = &none;
    if (args_opt) {
        args = args_opt;
    }
    if (name == "cpp") {
        return this.cpp_call(gargs, args, span);
    }
    if (name == "sizeof" || name == "alignof") {
        if (args.len != 1) {
            return fail(span, fmt("@{} takes 1 argument(s)", S(name)));
        }
        val t = try this.garg_type(args.at(0));
        if (name == "sizeof") {
            return vpure(USIZE, this.ir.node(ir_kind::SIZEOF(t), USIZE));
        }
        return vpure(USIZE, this.ir.node(ir_kind::ALIGNOF(t), USIZE));
    }
    if (name == "expand") {
        // @expand(x): x, and a note saying what it became: a comptime value, or the fn instance a
        // call runs
        if (args.len != 1) {
            return fail(span, fmt("@{} takes 1 argument(s)", S(name)));
        }
        val x = try this.garg_value(args.at(0));
        var is_call = false;
        match (x.kind) {
            .CALL(f, a) => { is_call = !this.is_ct_expr(x); },
            default => {},
        }
        var what: std::string = {};
        var v: tval = vpure(VOID, this.ir.boolean(false));
        var known: cval? = null;
        if (!is_call) {
            known = this.try_ct_eval(x, want);
        }
        if (known) {
            val text = this.cval_text(&known);
            v = try this.ct_to_val(copy known, want, span);
            what = fmt2("{} ({})", move text, this.ty_name(v.ty));
        } else {
            // the call x is, not one in its arguments
            val outer = this.expand_span;
            this.expand_span = x.span;
            this.last_call = null;
            val r = this.expr(x, want);
            this.expand_span = outer;
            v = try r;
            val lc = this.last_call;
            if (is_call && lc != null) {
                what = fmt("a call of {}", this.inst_label(lc ?? 0));
            } else {
                what = fmt("a value of type {}", this.ty_name(v.ty));
            }
        }
        // a call's instance is already recorded where it's emitted
        if (known) {
            this.expanded(span, copy what);
        }
        put(&this.warnings, { span: span, msg: fmt("expands to {}", move what), warning: true });
        return v;
    }
    if (name == "field") {
        if (args.len != 2) {
            return fail(span, fmt("@{} takes 2 argument(s)", S(name)));
        }
        val fe = try this.field_form(args.at(0), args.at(1), span);
        return this.expr(&fe, want);
    }
    if (name == "offsetof") {
        if (args.len != 2) {
            return fail(span, fmt("@{} takes 2 argument(s)", S(name)));
        }
        val t = try this.garg_type(args.at(0));
        val f = garg_name(args.at(1)) ?? return fails(span, "@offsetof(T, field) needs a field name");
        match (*this.t.get(t)) {
            .STRUCT(sid) => {
                val fs = try this.struct_fields(sid, span);
                for (i) in 0..fs.len {
                    if (fs.at(i).name == f) {
                        return vpure(USIZE, this.ir.node(ir_kind::OFFSETOF(t, @cast<u32>(i)), USIZE));
                    }
                }
            },
            default => {},
        }
        return fail(span, fmt2("{} has no field '{}'", this.ty_name(t), S(f)));
    }
    if (name == "cast") {
        if (args.len != 1) {
            return fail(span, fmt("@{} takes 1 argument(s)", S(name)));
        }
        if (gargs.len != 1) {
            return fails(span, "@cast<T>(x) needs one type");
        }
        val to = try this.garg_type(gargs.at(0));
        // a function's name cast to a pointer is its address (expr's fn-name case)
        val e = try this.garg_value(args.at(0));
        var want: u32? = null;
        match (e.kind) {
            .PATH(p) => {
                match (*this.t.get(to)) {
                    .VOIDPTR => { want = to; },
                    .PTR(x) => { want = to; },
                    .FN_PTR(a, b, c) => { want = to; },
                    default => {},
                }
            },
            default => {},
        }
        val v = try this.expr(e, want);
        if (this.cast_scalar(v.ty) && this.cast_scalar(to)) {
            var r = vnew(to, this.ir.conv(v.c, to));
            r.pure = v.pure;
            return r;
        }
        return vnew(to, this.ir.bitcast(v.c, to));
    }
    if (name == "bitcast") {
        // the same bits read as another type of the same size: an f64's as a u64 and back. Plain
        // data only: a box's or a string's bits copied would be owned twice
        if (args.len != 1) {
            return fail(span, fmt("@{} takes 1 argument(s)", S(name)));
        }
        if (gargs.len != 1) {
            return fails(span, "@bitcast<T>(x) needs one type");
        }
        val to = try this.garg_type(gargs.at(0));
        val v = try this.garg_expr(args.at(0), null);
        if (try this.needs_drop(v.ty)) {
            return fail(span, fmt("@bitcast takes plain data, not a {}", this.ty_name(v.ty)));
        }
        if (try this.needs_drop(to)) {
            return fail(span, fmt("@bitcast takes plain data, not a {}", this.ty_name(to)));
        }
        val a = try this.layout(v.ty, span);
        val b = try this.layout(to, span);
        if (a.size != b.size) {
            var m = S("@bitcast needs types of one size: ");
            m.append(this.ty_name(v.ty).as_str());
            m.append(" is ");
            m.append_uint(a.size);
            m.append(" bytes, ");
            m.append(this.ty_name(to).as_str());
            m.append(" is ");
            m.append_uint(b.size);
            return fail(span, move m);
        }
        return vnew(to, this.ir.bitcast(v.c, to));
    }
    if (name == "write") {
        // store into memory without deleting what was there (it isn't a value yet)
        if (args.len != 2) {
            return fail(span, fmt("@{} takes 2 argument(s)", S(name)));
        }
        val p = try this.garg_expr(args.at(0), null);
        val t = this.pointee(p.ty) ?? return fails(span, "@write(p, v) needs a T* first");
        // a store through p, like *p = v (lends.volt)
        var place = vnew(t, 0);
        place.lv = true;
        place.mutable = true;
        through(&place, p);
        if (!place.mutable) {
            return fails(span, "can't assign through this; it reaches a val (or a parameter without var)");
        }
        this.note_write(&place);
        var v = try this.garg_expr(args.at(1), t);
        v = try this.take(v, span);
        v = try this.coerce(v, t, span);
        val tw = this.tmp_local("w", p.ty);
        return this.vstmt(this.ir.seq(nodes2(this.ir.decl(tw.id, p.c), this.ir.assign(this.ir.deref(tw.c, t), v.c)), null, VOID));
    }
    if (name == "slice") {
        // unchecked: a slice over len values starting at ptr
        if (args.len != 2) {
            return fail(span, fmt("@{} takes 2 argument(s)", S(name)));
        }
        val p = try this.garg_expr(args.at(0), null);
        val t = this.pointee(p.ty) ?? return fails(span, "@slice(p, len) needs a T* first");
        var n = try this.garg_expr(args.at(1), USIZE);
        n = try this.coerce(n, USIZE, span);
        val st = this.t.intern(tyk::SLICE(t));
        var inits: std::vec<field_init> = {};
        put(&inits, { field: 0, value: p.c });
        put(&inits, { field: 1, value: n.c });
        // the slice points where p does
        var r = vnew(st, this.ir.node(ir_kind::AGG(move inits), st));
        r.ro = p.ro;
        r.via = p.via;
        r.root = p.root;
        return r;
    }
    if (name == "read") {
        // move the value out of memory without copying or deleting it (the opposite of @write)
        if (args.len != 1) {
            return fail(span, fmt("@{} takes 1 argument(s)", S(name)));
        }
        val p = try this.garg_expr(args.at(0), null);
        val t = this.pointee(p.ty) ?? return fails(span, "@read(p) needs a T*");
        // what's read points where *p does
        var r = vnew(t, this.ir.deref(p.c, t));
        r.ro = p.ro >> 1;
        r.via = deeper(p.via, 1);
        r.root = p.root;
        return r;
    }
    if (name == "volatile_read" || name == "volatile_write") {
        // a load or store the compiler keeps, in order, exactly as written: memory-mapped hardware
        // registers
        var want_args: usize = 2;
        if (name == "volatile_read") {
            want_args = 1;
        }
        if (args.len != want_args) {
            return fail(span, fmt2("@{} takes {} argument(s)", S(name), unum(@cast<u64>(want_args))));
        }
        val p = try this.garg_expr(args.at(0), null);
        val t = this.pointee(p.ty) ?? return fail(span, fmt("@{} needs a T* first", S(name)));
        if (try this.needs_drop(t)) {
            return fail(span, fmt2("@{} takes plain values (ints, floats, pointers), not a {}", S(name), this.ty_name(t)));
        }
        if (name == "volatile_read") {
            return vnew(t, this.ir.node(ir_kind::VLOAD(p.c), t));
        }
        var place = vnew(t, 0);
        place.lv = true;
        place.mutable = true;
        through(&place, p);
        if (!place.mutable) {
            return fails(span, "can't assign through this; it reaches a val (or a parameter without var)");
        }
        this.note_write(&place);
        var v = try this.garg_expr(args.at(1), t);
        v = try this.coerce(v, t, span);
        return this.vstmt(this.ir.node(ir_kind::VSTORE(p.c, v.c), VOID));
    }
    if (name == "typeid") {
        // @typeid(T), or @typeid(x): x's type's id, and for a trait value the id of the type it
        // holds, read from its tag (C++'s typeid of a polymorphic object, without a vtable)
        if (args.len != 1) {
            return fail(span, fmt("@{} takes 1 argument(s)", S(name)));
        }
        val u64t = int_id(int_ty::U64);
        var local = false;
        val n = garg_name(args.at(0));
        if (n) {
            val c = this.const_local(n);
            if (c) {
                match (c) {
                    .TYPE(t) => { return vpure(u64t, this.ir.int(@cast<i128>(this.type_id(t)), u64t)); },
                    default => {},
                }
            }
            local = this.lookup_local(n) != null;
        }
        if (!local) {
            val t = this.garg_type(args.at(0)) catch |x| NO_TY;
            if (t != NO_TY) {
                return vpure(u64t, this.ir.int(@cast<i128>(this.type_id(t)), u64t));
            }
        }
        val v = try this.garg_expr(args.at(0), null);
        // a trait value, or a reference to one
        var u: u32? = null;
        var place = v.c;
        match (*this.t.get(v.ty)) {
            .TRAIT_UNION(x) => {
                if (!v.lv && try this.needs_drop(v.ty)) {
                    return fails(span, "@typeid of a temporary trait value that owns memory; give it a name first");
                }
                u = x;
            },
            .REF(r) => {
                match (*this.t.get(r)) {
                    .TRAIT_UNION(x) => {
                        u = x;
                        place = this.ir.deref(v.c, r);
                    },
                    default => {},
                }
            },
            default => {},
        }
        val tu = u ?? return vpure(u64t, this.ir.int(@cast<i128>(this.type_id(v.ty)), u64t));
        // tag == 0 ? id0 : tag == 1 ? id1 : ... idN
        val members = copy this.ui(tu).members;
        if (members.len == 0) {
            // nothing implements the trait, so no value of it exists to ask
            return vpure(u64t, this.ir.int(0, u64t));
        }
        val u16t = int_id(int_ty::U16);
        val tag = this.tmp_local("tag", u16t);
        var r = this.ir.int(@cast<i128>(this.type_id(*members.at(members.len - 1))), u64t);
        var i = members.len - 1;
        while (i > 0) {
            i -= 1;
            val is = this.ir.binary(binop_ir::EQ, tag.c, this.ir.int(@cast<i128>(i), u16t), BOOL);
            r = this.ir.node(ir_kind::COND(is, this.ir.int(@cast<i128>(this.type_id(*members.at(i))), u64t), r), u64t);
        }
        return vnew(u64t, this.ir.seq(nodes(this.ir.decl(tag.id, this.ir.field(place, 0, u16t))), r, u64t));
    }
    if (name == "discriminant") {
        // which variant an enum value holds: its discriminant, as @typeinfo's variants list it
        if (args.len != 1) {
            return fail(span, fmt("@{} takes 1 argument(s)", S(name)));
        }
        val v = try this.garg_expr(args.at(0), null);
        var t = v.ty;
        var c = v.c;
        val inner = this.t.ref_inner(v.ty);
        if (inner) {
            t = inner;
            c = this.ir.deref(v.c, inner);
        }
        val eid = this.enum_of(t) ?? return fail(span, fmt("@discriminant takes an enum value, found {}", this.ty_name(t)));
        // a temporary that owns something is deleted once its tag is read
        if (!v.lv && t == v.ty && (try this.needs_drop(t))) {
            val td = this.tmp_local("d", t);
            val tt = this.tmp_local("t", I64);
            val d = try this.drop_fn(t);
            var stmts: std::vec<u32> = {};
            put(&stmts, this.ir.decl(td.id, c));
            put(&stmts, this.ir.decl(tt.id, this.ir.conv(this.tag_of(eid, td.c), I64)));
            put(&stmts, this.call_fn(d, nodes(this.ir.addr(td.c, this.t.ref_to(t))), VOID));
            return vnew(I64, this.ir.seq(move stmts, tt.c, I64));
        }
        var r = vnew(I64, this.ir.conv(this.tag_of(eid, c), I64));
        r.pure = v.pure;
        return r;
    }
    if (name == "panic") {
        if (args.len != 1) {
            return fail(span, fmt("@{} takes 1 argument(s)", S(name)));
        }
        var v = try this.garg_expr(args.at(0), STR);
        v = try this.coerce(v, STR, span);
        val loc = this.ir.node(ir_kind::CSTR(this.loc(span)), CSTR);
        return vnew(NEVER, this.ir.rt_call("volt_panic_str", nodes2(v.c, loc), NEVER));
    }
    return fail(span, fmt("unknown builtin @{}", S(name)));
}

// what a T& or T* points at
attach fn pointee(this: checker&, t: u32) -> u32? {
    match (*this.t.get(t)) {
        .REF(x) => { return x; },
        .PTR(x) => { return x; },
        default => { return null; },
    }
}
