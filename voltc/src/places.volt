// Places (fields, indexing, slicing) and aggregates (tuples, struct literals, ranges).
// A port of bootstrap/check/places.rs.
use std::mem;

// an @owns struct's owning field (its index and name) and the type it owns
struct owner_info {
    index: u32; // the pointer field
    name: str;
    inner: u32; // what it owns
}

// an @owns struct: its pointer field and what it owns
attach fn owner(this: checker&, t: u32) -> owner_info? {
    match (*this.t.get(t)) {
        .STRUCT(s) => {
            val info = this.si(s);
            val f = info.owns_field ?? return null;
            var idx: u32 = 0;
            match (this.item_of(info.decl).kind) {
                .STRUCT(sd) => {
                    for (i) in 0..sd.fields.len {
                        if (sd.fields.at(i).name == f) {
                            idx = @cast<u32>(i);
                        }
                    }
                },
                default => {},
            }
            return { index: idx, name: f, inner: info.owns_ty };
        },
        default => { return null; },
    }
}

// what an @owns struct (like std's box) points at
attach fn box_inner(this: checker&, t: u32) -> u32? {
    val o = this.owner(t) ?? return null;
    return o.inner;
}

// ---------- places ----------

// `b.name`: a struct or tuple field, a slice's or str's len/ptr, an array's len, or an optional's
// or error union's own fields (wrapper_field). A reference is seen through.
attach fn field(this: checker&, b0: tval, name: str, span: span) -> compile_error!tval {
    // .value/.none/.err see through a reference, like struct fields
    var b = b0;
    match (*this.t.get(b.ty)) {
        .REF(d) => {
            var wrapper = false;
            match (*this.t.get(d)) {
                .OPT(x) => { wrapper = true; },
                .ERR_UNION(x, y) => { wrapper = true; },
                default => {},
            }
            if (wrapper) {
                var v = vnew(d, this.ir.deref(b.c, d));
                v.lv = true;
                v.mutable = true;
                v.pure = b.pure;
                through(&v, b);
                b = v;
            }
        },
        default => {},
    }
    val w = try this.wrapper_field(&b, name, span);
    if (w) {
        return w;
    }
    match (*this.t.get(b.ty)) {
        .PTR(x) => { return fail(span, fmt2("this is a pointer ({}); reach what it points at with ->: p->{}", this.ty_name(b.ty), S(name))); },
        default => {},
    }
    val base_ty = this.t.ref_inner(b.ty) ?? b.ty;
    // an owning pointer (@owns) is used like its T&: names it doesn't have itself go to the T
    val own = this.owner(base_ty);
    if (own) {
        var sid: u32 = 0;
        match (*this.t.get(base_ty)) {
            .STRUCT(s) => { sid = s; },
            default => {},
        }
        var has_own = false;
        for (f&) in (try this.struct_fields(sid, span)).items() {
            if (f.name == name) {
                has_own = true;
            }
        }
        if (!has_own) {
            val o = own;
            var obj = b.c;
            if (base_ty != b.ty) {
                obj = this.ir.deref(b.c, base_ty);
            }
            val rt = this.t.ref_to(o.inner);
            var fv = vnew(rt, this.ir.field(obj, o.index, rt));
            fv.lv = true;
            fv.mutable = true;
            fv.pure = b.pure;
            return this.field(fv, name, span);
        }
    }
    // a field of a temporary that owns something: copy the field out, then delete the temporary
    if (!b.lv && base_ty == b.ty && (try this.needs_drop(b.ty))) {
        val ft = this.tmp_local("ft", b.ty);
        var tv = vpure(b.ty, ft.c);
        tv.lv = true;
        val f = try this.field(tv, name, span);
        if (try this.needs_drop(f.ty)) {
            return fails(span, "can't take a field that owns something out of a temporary; store the value in a variable first");
        }
        val fv = this.tmp_local("fv", f.ty);
        val d = try this.drop_fn(b.ty);
        var stmts: std::vec<u32> = {};
        put(&stmts, this.ir.decl(ft.id, b.c));
        put(&stmts, this.ir.decl(fv.id, f.c));
        put(&stmts, this.call_fn(d, nodes(this.ir.addr(ft.c, this.t.ref_to(b.ty))), VOID));
        return vnew(f.ty, this.ir.seq(move stmts, fv.c, f.ty));
    }
    var t = b.ty;
    var obj = b.c;
    var lv = b.lv;
    var mutable = b.mutable;
    var rop = b.rop;
    var pvia = b.pvia;
    var own = b.own;
    // what the struct's references point at: through b, one depth further than b's own
    var fro = b.ro;
    var fvia = b.via;
    val inner = this.t.ref_inner(b.ty);
    if (inner) {
        own = null;
        t = inner;
        obj = this.ir.deref(b.c, t);
        lv = true;
        mutable = (b.ro & 1) == 0;
        rop = (b.ro & 1) != 0;
        pvia = b.via;
        fro = b.ro >> 1;
        fvia = deeper(b.via, 1);
    }
    match (*this.t.get(t)) {
        .STRUCT(sid) => {
            val fs = try this.struct_fields(sid, span);
            for (i) in 0..fs.len {
                val f = fs.at(i);
                if (f.name == name) {
                    if (this.opts.lsp) {
                        this.lsp_field_use(sid, name, f.ty, span);
                    }
                    var r = vnew(f.ty, this.ir.field(obj, @cast<u32>(i), f.ty));
                    r.lv = lv;
                    r.mutable = mutable;
                    r.pure = b.pure;
                    r.rop = rop;
                    r.pvia = pvia;
                    // what a pointer field points at isn't part of the place, but it points where
                    // the struct's references do
                    r.ro = fro;
                    r.via = fvia;
                    r.root = b.root;
                    r.own = own;
                    return r;
                }
            }
        },
        .TUPLE(ts, names) => {
            var idx: usize? = parse_index(name);
            if (idx == null) {
                for (i) in 0..names.len {
                    val n = *names.at(i);
                    if (n != null && (n ?? "") == name) {
                        idx = i;
                    }
                }
            }
            if (idx != null && (idx ?? 0) < ts.len) {
                val i = idx ?? 0;
                val et = *ts.at(i);
                var r = vnew(et, this.ir.field(obj, @cast<u32>(i), et));
                r.lv = lv;
                r.mutable = mutable;
                r.pure = b.pure;
                r.rop = rop;
                r.pvia = pvia;
                r.ro = fro;
                r.via = fvia;
                r.root = b.root;
                r.own = own;
                return r;
            }
        },
        // a variant's payload, in place; a debug build checks the value holds that variant
        .ENUM(eid) => {
            val vi = this.variant_index(eid, name);
            if (vi) {
                val idx = vi;
                val payload = *(try this.enum_payloads(eid, span)).at(idx);
                val pt = payload ?? return fail(span, fmt("{} has no payload", S(name)));
                val fi = @cast<u32>(idx) + 1;
                var r = vnew(pt, this.ir.field(obj, fi, pt));
                if (!this.opts.release) {
                    val msg = this.intern(fmt("reading {}'s payload, but the value is another variant", S(name)));
                    val k = this.tag_const(eid, idx);
                    var stmts: std::vec<u32> = {};
                    if (lv) {
                        val ept = this.t.intern(tyk::PTR(t));
                        val ppt = this.t.intern(tyk::PTR(pt));
                        val te = this.tmp_local("e", ept);
                        val e = this.ir.deref(te.c, t);
                        put(&stmts, this.ir.decl(te.id, this.ir.addr(obj, ept)));
                        put(&stmts, this.ir.if_(this.ir.binary(binop_ir::NE, this.tag_of(eid, e), k, BOOL), this.ir.panic(msg, this.loc(span)), null));
                        r.c = this.ir.deref(this.ir.seq(move stmts, this.ir.addr(this.ir.field(e, fi, pt), ppt), ppt), pt);
                    } else {
                        val te = this.tmp_local("e", t);
                        put(&stmts, this.ir.decl(te.id, obj));
                        put(&stmts, this.ir.if_(this.ir.binary(binop_ir::NE, this.tag_of(eid, te.c), k, BOOL), this.ir.panic(msg, this.loc(span)), null));
                        r.c = this.ir.seq(move stmts, this.ir.field(te.c, fi, pt), pt);
                    }
                }
                r.lv = lv;
                r.mutable = mutable;
                r.pure = b.pure;
                r.rop = rop;
                r.pvia = pvia;
                r.ro = fro;
                r.via = fvia;
                r.root = b.root;
                r.own = own;
                return r;
            }
        },
        .SLICE(et) => {
            if (name == "len") {
                var r = vnew(USIZE, this.ir.field(obj, 1, USIZE));
                r.pure = b.pure;
                return r;
            }
            if (name == "ptr") {
                val pt = this.t.intern(tyk::PTR(et));
                var r = vnew(pt, this.ir.field(obj, 0, pt));
                r.pure = b.pure;
                return r;
            }
        },
        .STR => {
            if (name == "len") {
                var r = vnew(USIZE, this.ir.field(obj, 1, USIZE));
                r.pure = b.pure;
                return r;
            }
            if (name == "ptr") {
                val pt = this.t.intern(tyk::PTR(U8));
                var r = vnew(pt, this.ir.conv(this.ir.field(obj, 0, pt), pt));
                r.pure = b.pure;
                return r;
            }
        },
        .ARRAY(et, n) => {
            if (name == "len") {
                return vpure(USIZE, this.ir.int(@cast<i128>(n), USIZE));
            }
        },
        default => {},
    }
    // the fields (or tuple element names) it could have meant
    var names: std::vec<str> = {};
    match (*this.t.get(t)) {
        .STRUCT(sid) => {
            for (f&) in (try this.struct_fields(sid, span)).items() {
                put(&names, f.name);
            }
        },
        .TUPLE(ts, tnames) => {
            for (n&) in tnames.items() {
                if (*n != null) {
                    put(&names, *n ?? "");
                }
            }
        },
        default => {},
    }
    return this.no_field(span, t, name, &names);
}

// "3" -> 3 (tuple fields by position)
fn parse_index(s: str) -> usize? {
    if (s.len == 0) {
        return null;
    }
    var n: usize = 0;
    for (c) in s {
        if (c < '0' || c > '9') {
            return null;
        }
        n = n * 10 + @cast<usize>(c - '0');
    }
    return n;
}

// if (i >= len) volt_bounds(i, len, loc)
attach fn bounds_check(this: checker&, i: u32, len: u32, loc: str) -> u32 {
    val big = this.ir.binary(binop_ir::GE, i, len, BOOL);
    val call = this.ir.rt_call("volt_bounds", nodes3(i, len, this.ir.node(ir_kind::CSTR(loc), CSTR)), NEVER);
    return this.ir.if_(big, call, null);
}

// `b[i]`, bounds-checked in debug builds for arrays, slices and strs (pointers and cstrs aren't);
// `b[lo..hi]` is slice_expr
attach fn index(this: checker&, be: expr&, ie: expr&, span: span) -> compile_error!tval {
    match (ie.kind) {
        .RANGE(lo&, hi&, incl) => { return this.slice_expr(be, ptr_box(lo), ptr_box(hi), incl, span); },
        default => {},
    }
    var b = try this.expr(be, null);
    val inner = this.t.ref_inner(b.ty);
    if (inner) {
        val r0 = b;
        b.ty = inner;
        b.c = this.ir.deref(b.c, b.ty);
        b.lv = true;
        b.mutable = true;
        through(&b, r0);
    }
    var ia: std::vec<expr> = {};
    put(&ia, copy *ie);
    val called = try this.op_call("[]", b, &ia, null, span);
    if (called) {
        // a reference it gives back is a place
        val v = called;
        val t = this.t.ref_inner(v.ty);
        if (t == null) {
            return v;
        }
        var r = vnew(t ?? 0, this.ir.deref(v.c, t ?? 0));
        r.lv = true;
        r.mutable = true;
        r.pure = v.pure;
        through(&r, v);
        return r;
    }
    val i = try this.expr(ie, USIZE);
    if (this.t.int_of(i.ty) == null) {
        return fail(ie.span, fmt("index must be an integer, found {}", this.ty_name(i.ty)));
    }
    match (*this.t.get(b.ty)) {
        .PTR(t) => {
            // p[i]: unchecked, like C
            var pair: std::vec<tval> = {};
            put(&pair, b);
            put(&pair, i);
            val pre = this.seq_vals(&pair);
            val c = this.ir.index(pair.at(0).c, pair.at(1).c, t);
            var r = vnew(t, c);
            if (pre.len > 0) {
                val pt = this.t.intern(tyk::PTR(t));
                r.c = this.ir.deref(this.ir.seq(move pre, this.ir.addr(c, pt), pt), t);
            }
            r.lv = true;
            r.mutable = true;
            through(&r, b);
            return r;
        },
        default => {},
    }
    val loc = this.loc(span);
    val ti = this.tmp_local("i", USIZE);
    var stmts: std::vec<u32> = {};
    var elem: u32 = 0;
    var c: u32 = 0;
    var lv = false;
    match (*this.t.get(b.ty)) {
        .ARRAY(t, n) => {
            elem = t;
            val pt = this.t.intern(tyk::PTR(t));
            if (b.lv) {
                put(&stmts, this.ir.decl(ti.id, this.ir.conv(i.c, USIZE)));
                if (!this.opts.release) {
                    put(&stmts, this.bounds_check(ti.c, this.ir.int(@cast<i128>(n), USIZE), loc));
                }
                c = this.ir.deref(this.ir.seq(copy stmts, this.ir.addr(this.ir.index(b.c, ti.c, t), pt), pt), t);
                lv = true;
            } else {
                val ta = this.tmp_local("a", b.ty);
                put(&stmts, this.ir.decl(ta.id, b.c));
                put(&stmts, this.ir.decl(ti.id, this.ir.conv(i.c, USIZE)));
                if (!this.opts.release) {
                    put(&stmts, this.bounds_check(ti.c, this.ir.int(@cast<i128>(n), USIZE), loc));
                }
                c = this.ir.seq(copy stmts, this.ir.index(ta.c, ti.c, t), t);
            }
        },
        .SLICE(t) => {
            elem = t;
            val pt = this.t.intern(tyk::PTR(t));
            val ts = this.tmp_local("s", b.ty);
            put(&stmts, this.ir.decl(ts.id, b.c));
            put(&stmts, this.ir.decl(ti.id, this.ir.conv(i.c, USIZE)));
            if (!this.opts.release) {
                put(&stmts, this.bounds_check(ti.c, this.ir.field(ts.c, 1, USIZE), loc));
            }
            val at = this.ir.index(this.ir.field(ts.c, 0, pt), ti.c, t);
            c = this.ir.deref(this.ir.seq(copy stmts, this.ir.addr(at, pt), pt), t);
            lv = true;
        },
        .STR => {
            elem = U8;
            val pt = this.t.intern(tyk::PTR(U8));
            val ts = this.tmp_local("s", STR);
            put(&stmts, this.ir.decl(ts.id, b.c));
            put(&stmts, this.ir.decl(ti.id, this.ir.conv(i.c, USIZE)));
            if (!this.opts.release) {
                put(&stmts, this.bounds_check(ti.c, this.ir.field(ts.c, 1, USIZE), loc));
            }
            c = this.ir.seq(copy stmts, this.ir.index(this.ir.field(ts.c, 0, pt), ti.c, U8), U8);
        },
        .CSTR => {
            elem = U8;
            c = this.ir.index(b.c, i.c, U8);
        },
        default => { return fail(span, fmt2("can't index a {}{}", this.ty_name(b.ty), this.op_hint(b.ty, "[]"))); },
    }
    var is_slice = false;
    match (*this.t.get(b.ty)) {
        .SLICE(x) => { is_slice = true; },
        default => {},
    }
    // a slice's elements are what it points at; an array's are part of it
    var r = vnew(elem, c);
    r.lv = lv;
    r.mutable = lv;
    if (is_slice) {
        through(&r, b);
    } else {
        r.mutable = lv && b.mutable;
        r.rop = b.rop;
        r.pvia = b.pvia;
        r.ro = b.ro;
        r.via = b.via;
        r.root = b.root;
        r.own = b.own;
    }
    return r;
}

// `b[lo..hi]` (either end optional): a slice of an array or slice, a str of a str. Debug builds
// check lo <= hi <= len.
attach fn slice_expr(this: checker&, be: expr&, lo: expr*, hi: expr*, incl: bool, span: span) -> compile_error!tval {
    var b = try this.expr(be, null);
    val inner = this.t.ref_inner(b.ty);
    if (inner) {
        val r0 = b;
        b.ty = inner;
        b.c = this.ir.deref(b.c, b.ty);
        b.lv = true;
        b.mutable = true;
        through(&b, r0);
    }
    // the slice reaches the array (as &array would) or what the sliced slice does
    var sv = vnew(0, 0);
    addr_prov(&sv, &b);
    this.note_mut(&b);
    match (*this.t.get(b.ty)) {
        .SLICE(x) => {
            sv.ro = b.ro;
            sv.via = b.via;
        },
        default => {},
    }
    var lo_c = this.ir.int(0, USIZE);
    if (lo) {
        lo_c = (try this.expr_as(lo, USIZE)).c;
    }
    var elem: u32 = 0;
    var base: u32 = 0;
    var len: u32 = 0;
    var out_ty: u32? = null;
    var bind: u32? = null;
    match (*this.t.get(b.ty)) {
        .ARRAY(t, n) => {
            if (!b.lv) {
                return fails(be.span, "can't slice a temporary array; store it in a variable first");
            }
            elem = t;
            val pt = this.t.intern(tyk::PTR(t));
            base = this.ir.addr(this.ir.index(b.c, this.ir.int(0, USIZE), t), pt);
            len = this.ir.int(@cast<i128>(n), USIZE);
        },
        .SLICE(t) => {
            elem = t;
            val pt = this.t.intern(tyk::PTR(t));
            val tb = this.tmp_local("b", b.ty);
            bind = this.ir.decl(tb.id, b.c);
            base = this.ir.field(tb.c, 0, pt);
            len = this.ir.field(tb.c, 1, USIZE);
        },
        .STR => {
            elem = U8;
            val pt = this.t.intern(tyk::PTR(U8));
            val tb = this.tmp_local("b", STR);
            bind = this.ir.decl(tb.id, b.c);
            base = this.ir.field(tb.c, 0, pt);
            len = this.ir.field(tb.c, 1, USIZE);
            out_ty = STR;
        },
        default => { return fail(span, fmt("can't slice a {}", this.ty_name(b.ty))); },
    }
    val out = out_ty ?? this.t.intern(tyk::SLICE(elem));
    var hi_c = len;
    if (hi) {
        val h = (try this.expr_as(hi, USIZE)).c;
        hi_c = h;
        if (incl) {
            hi_c = this.ir.binary(binop_ir::ADD, h, this.ir.int(1, USIZE), USIZE);
        }
    }
    val tlo = this.tmp_local("lo", USIZE);
    val thi = this.tmp_local("hi", USIZE);
    var stmts: std::vec<u32> = {};
    if (bind) {
        put(&stmts, bind);
    }
    put(&stmts, this.ir.decl(tlo.id, lo_c));
    put(&stmts, this.ir.decl(thi.id, hi_c));
    if (!this.opts.release) {
        val bad = this.ir.binary(binop_ir::OR, this.ir.binary(binop_ir::GT, tlo.c, thi.c, BOOL), this.ir.binary(binop_ir::GT, thi.c, len, BOOL), BOOL);
        val call = this.ir.rt_call("volt_bounds", nodes3(thi.c, len, this.ir.node(ir_kind::CSTR(this.loc(span)), CSTR)), NEVER);
        put(&stmts, this.ir.if_(bad, call, null));
    }
    val pt = this.t.intern(tyk::PTR(elem));
    var inits: std::vec<field_init> = {};
    put(&inits, { field: 0, value: this.ir.binary(binop_ir::ADD, base, tlo.c, pt) });
    put(&inits, { field: 1, value: this.ir.binary(binop_ir::SUB, thi.c, tlo.c, USIZE) });
    var r = vnew(out, this.ir.seq(move stmts, this.ir.node(ir_kind::AGG(move inits), out), out));
    r.ro = sv.ro;
    r.via = sv.via;
    r.root = sv.root;
    return r;
}

// ---------- aggregates ----------

attach fn tuple(this: checker&, elems: std::vec<expr>&, want: u32?, span: span) -> compile_error!tval {
    var ps: std::vec<expr*> = {};
    for (e&) in elems.items() {
        put(&ps, e);
    }
    return this.tuple_of(&ps, want, span);
}

// `(a, b, ...)`: the elements move in; a wanted tuple type of the same length types them
attach fn tuple_of(this: checker&, elems: std::vec<expr*>&, want0: u32?, span: span) -> compile_error!tval {
    // a tuple wanted inside an optional or an error union guides the elements too
    var want = want0;
    var peel = true;
    while (peel && want != null) {
        peel = false;
        match (*this.t.get(want ?? 0)) {
            .OPT(inner) => {
                want = inner;
                peel = true;
            },
            .ERR_UNION(e, inner) => {
                want = inner;
                peel = true;
            },
            default => {},
        }
    }
    var wants: std::vec<u32?> = {};
    var want_fits = false;
    if (want) {
        match (*this.t.get(want)) {
            .TUPLE(ts, names) => {
                if (ts.len == elems.len) {
                    want_fits = true;
                    for (t&) in ts.items() {
                        put(&wants, *t);
                    }
                }
            },
            default => {},
        }
    }
    if (!want_fits) {
        for (i) in 0..elems.len {
            put(&wants, null);
        }
    }
    var vals: std::vec<tval> = {};
    for (i) in 0..elems.len {
        val e = *elems.at(i) ?? return fails(span, "");
        val w = *wants.at(i);
        var v = try this.expr(e, w);
        v = try this.take(v, e.span);
        if (w) {
            v = try this.coerce(v, w, e.span);
        }
        put(&vals, v);
    }
    for (v&) in vals.items() {
        if (v.ty == VOID || v.ty == NULL_TY) {
            return fails(span, "tuple elements need a value type");
        }
    }
    var t: u32 = 0;
    if (want_fits) {
        t = want ?? 0;
    } else {
        var ts: std::vec<u32> = {};
        var names: std::vec<str?> = {};
        for (v&) in vals.items() {
            put(&ts, v.ty);
            put(&names, null);
        }
        t = this.t.intern(tyk::TUPLE(move ts, move names));
    }
    val pre = this.seq_vals(&vals);
    var inits: std::vec<field_init> = {};
    var pure = true;
    for (i) in 0..vals.len {
        put(&inits, { field: @cast<u32>(i), value: vals.at(i).c });
        pure = pure && vals.at(i).pure;
    }
    var r = vnew(t, this.wrap_pre(move pre, this.ir.node(ir_kind::AGG(move inits), t), t));
    r.pure = pure;
    this.merge_held(&r, &vals);
    return r;
}

// `{ x; n }`: an array of the wanted type (or one inside an optional or error union) holding n copies
// of x, which is evaluated once
attach fn repeat(this: checker&, x: expr&, n: expr&, want: u32?, span: span) -> compile_error!tval {
    val w = want ?? return fails(span, "can't tell what type this literal is; give the variable a type");
    var t: u32 = 0;
    var len: u64 = 0;
    match (*this.t.get(w)) {
        .OPT(inner) => {
            val v = try this.repeat(x, n, inner, span);
            return this.some(v, w);
        },
        .ERR_UNION(e, inner) => {
            val v = try this.repeat(x, n, inner, span);
            return this.coerce(v, w, span);
        },
        .ARRAY(et, k) => {
            t = et;
            len = k;
        },
        default => { return fail(span, fmt("a {{ x; n }} literal makes an array, not a {}", this.ty_name(w))); },
    }
    val count = this.const_int(n, this.cx.env) catch |e| {
        return fails(n.span, "a repeat count must be known at compile time");
    };
    if (count != @cast<i128>(len)) {
        return fail(span, fmt2("this repeats {} times but the array holds {}", num(count), unum(len)));
    }
    if (try this.needs_drop(t)) {
        return fail(x.span, fmt("can't repeat a {}: it owns memory; build the elements one by one", this.ty_name(t)));
    }
    val v0 = try this.expr(x, t);
    val v = try this.coerce(v0, t, x.span);
    var r = this.fill_array(w, t, len, v.c);
    var vs: std::vec<tval> = {};
    put(&vs, v);
    this.merge_held(&r, &vs);
    return r;
}

// an array of type at (len elements of type t) with every element set to c, evaluated once
attach fn fill_array(this: checker&, at: u32, t: u32, len: u64, c: u32) -> tval {
    val r = this.tmp_local("r", at);
    val v = this.tmp_local("v", t);
    val k = this.tmp_local("k", USIZE);
    val body = this.ir.assign(this.ir.index(r.c, k.c, t), v.c);
    var stmts: std::vec<u32> = {};
    put(&stmts, this.ir.decl(v.id, c));
    put(&stmts, this.ir.decl(r.id, null));
    for (s&) in this.counted_loop(k, this.ir.int(@cast<i128>(len), USIZE), body).items() {
        put(&stmts, *s);
    }
    return vnew(at, this.ir.seq(move stmts, r.c, at));
}

// A `{ ... }` literal of the wanted type: a struct (fields by name, the rest from their
// defaults), an array, a tuple, or one of those inside an optional or error union.
attach fn literal(this: checker&, entries: std::vec<lit_entry>&, want: u32?, span: span) -> compile_error!tval {
    val w = want ?? return fails(span, "can't tell what type this literal is; give the variable a type");
    match (*this.t.get(w)) {
        .OPT(inner) => {
            val v = try this.literal(entries, inner, span);
            return this.some(v, w);
        },
        .ERR_UNION(e, inner) => {
            val v = try this.literal(entries, inner, span);
            return this.coerce(v, w, span);
        },
        .STRUCT(sid) => {
            if (entries.len > 1 && this.union_struct(sid)) {
                return fails(span, "a C union's literal sets one member; assign another afterwards");
            }
            val fs = try this.struct_fields(sid, span);
            var given: std::vec<tval?> = {};
            for (i) in 0..fs.len {
                put(&given, null);
            }
            for (en&) in entries.items() {
                val e = &en.value;
                var n = "";
                if (en.name) {
                    n = en.name;
                } else {
                    var ok = false;
                    match (e.kind) {
                        .PATH(p) => {
                            if (p.is_single()) {
                                n = p.segs.at(0).name;
                                ok = true;
                            }
                        },
                        default => {},
                    }
                    if (!ok) {
                        return fails(e.span, "struct literal entries need names: { field: value }");
                    }
                }
                var idx: usize? = null;
                for (i) in 0..fs.len {
                    if (fs.at(i).name == n) {
                        idx = i;
                        break;
                    }
                }
                if (idx == null) {
                    var names: std::vec<str> = {};
                    for (f&) in fs.items() {
                        put(&names, f.name);
                    }
                    return this.no_field(e.span, w, n, &names);
                }
                val i = idx ?? 0;
                if (this.opts.lsp && en.name != null) {
                    // the name is the last time it's written before the value (`{ x: x }`)
                    this.lsp_field_use(sid, n, fs.at(i).ty, { file: e.span.file, lo: span.lo, hi: e.span.lo });
                }
                if (*given.at(i) != null) {
                    return fail(e.span, fmt("field '{}' is set twice", S(n)));
                }
                val ft = fs.at(i).ty;
                val v = try this.expr(e, ft);
                *given.at(i) = try this.take_into(v, ft, e.span);
            }
            // in declaration order; what's left out takes its default
            val header = this.header_struct(sid);
            var vals: std::vec<tval> = {};
            var kept: std::vec<u32> = {};
            val fs2 = try this.struct_fields(sid, span);
            for (i) in 0..fs2.len {
                val f = fs2.at(i);
                val g = *given.at(i);
                var is_array = false;
                match (*this.t.get(f.ty)) {
                    .ARRAY(x, y) => { is_array = true; },
                    default => {},
                }
                if (g) {
                    if (header && is_array) {
                        return fail(span, fmt("C array field '{}' can't be set in a literal; assign it afterwards", S(f.name)));
                    }
                    put(&vals, g);
                } else if (header) {
                    continue; // like C: what's left out is zero
                } else {
                    put(&vals, try this.field_default(sid, f, span));
                }
                put(&kept, @cast<u32>(i));
            }
            val pre = this.seq_vals(&vals);
            var inits: std::vec<field_init> = {};
            var pure = true;
            val fs3 = try this.struct_fields(sid, span);
            for (k) in 0..vals.len {
                val fi = *kept.at(k);
                pure = pure && vals.at(k).pure;
                if (fs3.at(@cast<usize>(fi)).ty != VOID) {
                    put(&inits, { field: fi, value: vals.at(k).c });
                }
            }
            var r = vnew(w, this.wrap_pre(move pre, this.ir.node(ir_kind::AGG(move inits), w), w));
            r.pure = pure;
            this.merge_held(&r, &vals);
            return r;
        },
        .ARRAY(t, n) => {
            if (entries.len == 0) {
                return this.zero_value(w, span); // {}: all zero, like a var without an initializer
            }
            if (@cast<u64>(entries.len) != n) {
                return fail(span, fmt2("expected {} elements, found {}", unum(n), unum(@cast<u64>(entries.len))));
            }
            var vals: std::vec<tval> = {};
            for (en&) in entries.items() {
                if (en.name != null) {
                    return fails(en.value.span, "array literals don't take names");
                }
                val v = try this.expr(&en.value, t);
                put(&vals, try this.take_into(v, t, en.value.span));
            }
            val pre = this.seq_vals(&vals);
            var cs: std::vec<u32> = {};
            var pure = true;
            for (v&) in vals.items() {
                put(&cs, v.c);
                pure = pure && v.pure;
            }
            var r = vnew(w, this.wrap_pre(move pre, this.ir.node(ir_kind::ARRAY_LIT(move cs), w), w));
            r.pure = pure;
            this.merge_held(&r, &vals);
            return r;
        },
        .TUPLE(ts, names) => {
            var ps: std::vec<expr*> = {};
            for (en&) in entries.items() {
                put(&ps, &en.value);
            }
            return this.tuple_of(&ps, want, span);
        },
        default => {},
    }
    return fail(span, fmt("a { } literal can't make a {}", this.ty_name(w)));
}

// value for a field left out of a struct literal
attach fn field_default(this: checker&, sid: u32, f: field_info&, span: span) -> compile_error!tval {
    if (f.fallback) {
        val e = this.si(sid).env;
        return this.in_env_expr_as(e, f.fallback, f.ty);
    }
    if (this.t.opt_inner(f.ty) != null) {
        return this.none(f.ty);
    }
    if (this.t.is_ptr(f.ty)) {
        return vpure(f.ty, this.ir.node(ir_kind::NULLPTR, f.ty)); // a pointer left out is null
    }
    if (f.name.len > 0 && f.name[0] == '@') {
        return vpure(f.ty, this.ir.zero(f.ty)); // padding (clang.volt's pad_fields) is zero
    }
    return fail(span, fmt("missing field '{}' (it has no default)", S(f.name)));
}

// check e as t in another env (callee/struct namespace), with the caller's locals hidden
attach fn in_env_expr_as(this: checker&, e: u32, x: expr&, t: u32) -> compile_error!tval {
    val saved = this.cx.env;
    this.cx.env = e;
    put(&this.cx.scopes, { barrier: true });
    val r = this.expr_as(x, t);
    this.cx.scopes.pop();
    this.cx.env = saved;
    return r;
}

// k = 0; loop { if (k >= n) break; body; k += 1; }
attach fn counted_loop(this: checker&, k: local_ref, n: u32, body: u32) -> std::vec<u32> {
    val end = this.ir.label();
    var inner: std::vec<u32> = {};
    put(&inner, this.ir.if_(this.ir.binary(binop_ir::GE, k.c, n, BOOL), this.ir.goto_(end), null));
    put(&inner, body);
    put(&inner, this.ir.assign(k.c, this.ir.binary(binop_ir::ADD, k.c, this.ir.int(1, USIZE), USIZE)));
    var out: std::vec<u32> = {};
    put(&out, this.ir.decl(k.id, this.ir.int(0, USIZE)));
    put(&out, this.ir.node(ir_kind::LOOP(this.ir.block(move inner)), VOID));
    put(&out, this.ir.label_at(end));
    return out;
}

// `lo..hi` as a range value (`for (i) in lo..hi` doesn't come here); a constant range wanted as an
// array fills the array instead
attach fn range_val(this: checker&, lo: expr*, hi: expr*, incl: bool, want: u32?, span: span) -> compile_error!tval {
    if (lo == null || hi == null) {
        return fails(span, "open ranges only work for slicing: a[1..], a[..2]");
    }
    val l = lo ?? return fails(span, "");
    val h = hi ?? return fails(span, "");
    // a range assigned to an array fills it
    if (want) {
        match (*this.t.get(want)) {
            .ARRAY(t, n) => {
                val w = want;
                val lv = try this.const_int(l, this.cx.env);
                val hv = try this.const_int(h, this.cx.env);
                var count = hv - lv;
                if (incl) {
                    count += 1;
                }
                if (count != @cast<i128>(n)) {
                    return fail(span, fmt2("this range has {} values but the array holds {}", num(count), unum(n)));
                }
                val first = try this.expr_as(l, t);
                val r = this.tmp_local("r", w);
                val k = this.tmp_local("k", USIZE);
                val sum = this.ir.binary(binop_ir::ADD, this.ir.conv(first.c, USIZE), k.c, USIZE);
                val body = this.ir.assign(this.ir.index(r.c, k.c, t), this.ir.conv(sum, t));
                var stmts: std::vec<u32> = {};
                put(&stmts, this.ir.decl(r.id, null));
                for (s&) in this.counted_loop(k, this.ir.int(@cast<i128>(n), USIZE), body).items() {
                    put(&stmts, *s);
                }
                return vnew(w, this.ir.seq(move stmts, r.c, w));
            },
            default => {},
        }
    }
    val a = try this.expr(l, null);
    val b = try this.expr(h, null);
    val u = try this.unify(a, b, span);
    if (this.t.int_of(u.a.ty) == null) {
        return fails(span, "ranges need integers");
    }
    // the value keeps an exclusive end; for lo..=MAX it overflows, which traps in debug builds
    var hi_c = u.b.c;
    if (incl) {
        val k = this.t.int_of(u.b.ty) ?? return fails(span, "ranges need integers");
        hi_c = try this.int_arith(binop::ADD, k, u.b.c, this.ir.int(1, u.b.ty), span, u.b.ty);
    }
    val t = this.t.intern(tyk::RANGE(u.a.ty));
    var inits: std::vec<field_init> = {};
    put(&inits, { field: 0, value: u.a.c });
    put(&inits, { field: 1, value: hi_c });
    return vnew(t, this.ir.node(ir_kind::AGG(move inits), t));
}
