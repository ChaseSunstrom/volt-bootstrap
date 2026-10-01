// Optionals and error unions: coercions, try, catch, ??, narrowing, .value/.none/.err. A port of
// bootstrap/check/errors.rs. A pointer-like optional (T&?, cstr?, fn?) is the pointer itself, null for
// none, so it shares its payload's representation.
use std::mem;

// whether v converts to `to` by the error rules. Into E!T: an error of set E (of any set when E is
// `error`), a value that coerces to T, or an E2!T when E is `error`. Into `error`: any error value
attach fn error_coercible(this: checker&, v: tval&, to: u32) -> bool {
    match (*this.t.get(to)) {
        .ERR_UNION(e, t) => {
            match (*this.t.get(v.ty)) {
                .ERR_UNION(e2, t2) => { return t2 == t && e == ANYERR && this.is_error_ty(e2); },
                default => {},
            }
            return (this.is_error_ty(v.ty) && (v.ty == e || e == ANYERR)) || (t != VOID && this.coercible(v, t));
        },
        .ANYERR => { return this.is_error_ty(v.ty); },
        default => { return false; },
    }
}

// the conversion error_coercible allows: an error goes in field 0 (.err), a payload in field 1 (.v), and
// another error union's error is re-coded as an `error` code
attach fn error_coerce(this: checker&, v: tval, to: u32, span: span) -> compile_error!tval {
    var e: u32 = 0;
    var t: u32 = 0;
    match (*this.t.get(to)) {
        .ERR_UNION(x, y) => {
            e = x;
            t = y;
        },
        .ANYERR => { return retyped(&v, ANYERR, this.err_code(v.ty, v.c)); },
        default => { return fails(span, "not an error union"); },
    }
    match (*this.t.get(v.ty)) {
        .ERR_UNION(x, y) => {
            val tmp = this.tmp_local("e", v.ty);
            var inits: std::vec<field_init> = {};
            put(&inits, { field: 0, value: this.eu_code(v.ty, tmp.c) });
            if (t != VOID) {
                put(&inits, { field: 1, value: this.ir.field(tmp.c, 1, t) });
            }
            val agg = this.ir.node(ir_kind::AGG(move inits), to);
            return vnew(to, this.ir.seq(nodes(this.ir.decl(tmp.id, v.c)), agg, to));
        },
        default => {},
    }
    if (this.is_error_ty(v.ty) && (v.ty == e || e == ANYERR)) {
        var conv = v.c;
        if (v.ty != e) {
            conv = this.err_code(v.ty, v.c);
        }
        var inits: std::vec<field_init> = {};
        put(&inits, { field: 0, value: conv });
        return retyped(&v, to, this.ir.node(ir_kind::AGG(move inits), to));
    }
    val inner = try this.coerce(v, t, span);
    var inits: std::vec<field_init> = {};
    put(&inits, { field: 1, value: inner.c });
    return retyped(&inner, to, this.ir.node(ir_kind::AGG(move inits), to));
}

// an error code (or error value) is set: it isn't 0
attach fn nonzero(this: checker&, c: u32) -> u32 {
    return this.ir.binary(binop_ir::NE, c, this.ir.int(0, this.ir.ty_of(c)), BOOL);
}

// `try x`: the payload of x, or on error runs every scope's errdefers and drops and returns the error
// (converted to the fn's error set, which must be x's set or `error`)
attach fn try_expr(this: checker&, x: expr&, span: span) -> compile_error!tval {
    val v0 = try this.expr(x, null);
    val v = try this.take(v0, x.span); // the payload comes out, so an owning local moves
    var e: u32 = 0;
    var t: u32 = 0;
    match (*this.t.get(v.ty)) {
        .ERR_UNION(a, b) => {
            e = a;
            t = b;
        },
        default => { return fail(x.span, fmt("try needs something that can fail (E!T), found {}", this.ty_name(v.ty))); },
    }
    val ret = this.cx.ret;
    var re: u32 = 0;
    match (*this.t.get(ret)) {
        .ERR_UNION(a, b) => { re = a; },
        default => { return fails(span, "try only works inside a function that returns an error union (E!T)"); },
    }
    if (e != re && re != ANYERR) {
        return fail(span, fmt2("this can fail with {}, but the function returns {} errors", this.ty_name(e), this.ty_name(re)));
    }
    val tmp = this.tmp_local("t", v.ty);
    val code = this.eu_code(v.ty, tmp.c);
    var conv = code;
    if (e == re) {
        conv = this.ir.field(tmp.c, 0, e);
    }
    val top = this.cx.scopes.len - 1;
    val defers = try this.scope_exit_code(top, 0, true);
    var inits: std::vec<field_init> = {};
    put(&inits, { field: 0, value: conv });
    val out = this.ir.node(ir_kind::AGG(move inits), ret);
    val exit = this.fn_exit(out, move defers, this.ret_slot());
    val stmts = nodes2(this.ir.decl(tmp.id, v.c), this.ir.if_(this.nonzero(code), exit, null));
    if (t == VOID) {
        return vnew(t, this.ir.seq(move stmts, null, t));
    }
    return vnew(t, this.ir.seq(move stmts, this.ir.field(tmp.c, 1, t), t));
}

// `x catch |e| handler`: the payload, or the handler's value on error. The handler may leave
// (return/break) instead; when x has no payload it must give no value
attach fn catch_expr(this: checker&, x: expr&, cap: catch_cap*, handler: expr&, span: span) -> compile_error!tval {
    val v0 = try this.expr(x, null);
    val v = try this.take(v0, x.span); // the payload comes out, so an owning local moves
    var e: u32 = 0;
    var t: u32 = 0;
    match (*this.t.get(v.ty)) {
        .ERR_UNION(a, b) => {
            e = a;
            t = b;
        },
        default => { return fail(x.span, fmt("catch needs something that can fail (E!T), found {}", this.ty_name(v.ty))); },
    }
    put(&this.cx.scopes, {});
    val r = this.catch_inner(v, e, t, cap, handler);
    this.cx.scopes.pop();
    return r;
}

// the rest of catch_expr, inside the scope that holds the captured error
attach fn catch_inner(this: checker&, v: tval, e: u32, t: u32, cap: catch_cap*, handler: expr&) -> compile_error!tval {
    val tmp = this.tmp_local("t", v.ty);
    val code = this.eu_code(v.ty, tmp.c);
    var arm: std::vec<u32> = {};
    // the handler owns the error: bound or not, one that needs delete is deleted when the handler
    // ends (or leaves early, through the scope's exits)
    var name: str? = null;
    if (cap) {
        name = (cap).name;
        this.lsp_at = (cap).span;
    } else if (try this.needs_drop(e)) {
        name = "@err";
    }
    if (name) {
        val o = try this.owned_local(name, e, false);
        put(&arm, this.decl_at(o.c, this.ir.field(tmp.c, 0, e)));
        if (o.flag) {
            put(&arm, o.flag);
        }
    }
    var want: u32? = null;
    if (t != VOID) {
        want = t;
    }
    val moved_before = copy this.cx.moved;
    val h = try this.expr(handler, want);
    if (h.ty == NEVER) {
        this.cx.moved = copy moved_before; // a handler that leaves moves nothing on the path that goes on
    }
    val first = this.ir.decl(tmp.id, v.c);
    val top = this.cx.scopes.len - 1;
    if (h.ty == NEVER || t == VOID) {
        if (h.ty != NEVER && h.ty != VOID) {
            return fails(handler.span, "this function gives no value, so catch shouldn't either");
        }
        put(&arm, h.c);
        if (h.ty != NEVER) {
            extend(&arm, try this.scope_exit_code(top, top, false));
        }
        val stmts = nodes2(first, this.ir.if_(this.nonzero(code), this.ir.block(move arm), null));
        if (t == VOID) {
            return vnew(t, this.ir.seq(move stmts, null, t));
        }
        return vnew(t, this.ir.seq(move stmts, this.ir.field(tmp.c, 1, t), t));
    }
    if (h.ty == VOID) {
        return fails(handler.span, "catch needs a value here, or a block that leaves (return/break)");
    }
    val hv = try this.coerce(h, t, handler.span);
    val r = this.tmp_local("r", t);
    put(&arm, this.ir.assign(r.c, hv.c));
    extend(&arm, try this.scope_exit_code(top, top, false));
    val els = this.ir.assign(r.c, this.ir.field(tmp.c, 1, t));
    val stmts = nodes3(first, this.ir.decl(r.id, null), this.ir.if_(this.nonzero(code), this.ir.block(move arm), els));
    return vnew(t, this.ir.seq(move stmts, r.c, t));
}

// an optional's present test and payload, as IR nodes (see opt_parts)
struct opt_split {
    has: u32;  // bool
    value: u32;
}

// is an optional present, and its payload (c is evaluated in both, so it should be a place or pure). A
// niche optional is the pointer itself, null for none; any other is { value, has }
attach fn opt_parts(this: checker&, opt: u32, c: u32) -> opt_split {
    val inner = this.t.opt_inner(opt) ?? VOID;
    if (this.t.is_niche(inner)) {
        val has = this.ir.binary(binop_ir::NE, c, this.ir.node(ir_kind::NULLPTR, opt), BOOL);
        return { has: has, value: c };
    }
    return { has: this.ir.field(c, 1, BOOL), value: this.ir.field(c, 0, inner) };
}

// `a ?? b`: a's payload, or b when a is none or null. b may leave instead (`?? return x`)
attach fn orelse(this: checker&, a: expr&, b: expr&, span: span) -> compile_error!tval {
    val a0 = try this.expr(a, null);
    val av = try this.take(a0, a.span); // the payload comes out, so an owning optional moves
    if (this.t.is_ptr(av.ty)) {
        // p ?? x: a T* that isn't null is a T& (void* stays void*)
        var res = av.ty;
        match (*this.t.get(av.ty)) {
            .PTR(inner) => { res = this.t.ref_to(inner); },
            default => {},
        }
        val moved_before = copy this.cx.moved;
        val bv = try this.expr(b, res);
        if (bv.ty == NEVER) {
            this.cx.moved = copy moved_before;
        }
        val o = this.tmp_local("o", av.ty);
        val first = this.ir.decl(o.id, av.c);
        val is_null = this.ir.binary(binop_ir::EQ, o.c, this.ir.node(ir_kind::NULLPTR, av.ty), BOOL);
        if (bv.ty == NEVER) {
            return vnew(res, this.ir.seq(nodes2(first, this.ir.if_(is_null, bv.c, null)), o.c, res));
        }
        val bc = try this.coerce(bv, res, span);
        // either one: read-only where either is (lends.volt)
        var r = vnew(res, this.ir.seq(nodes(first), this.ir.node(ir_kind::COND(is_null, bc.c, o.c), res), res));
        merge_prov(&r, &av);
        merge_prov(&r, &bc);
        return r;
    }
    val inner = this.t.opt_inner(av.ty) ?? return fail(a.span, fmt("?? needs an optional on the left, found {}", this.ty_name(av.ty)));
    val moved_before = copy this.cx.moved;
    val bv = try this.expr(b, inner);
    if (bv.ty == NEVER) {
        this.cx.moved = copy moved_before; // `?? return x` moves nothing on the path that goes on
    }
    val o = this.tmp_local("o", av.ty);
    val first = this.ir.decl(o.id, av.c);
    val p = this.opt_parts(av.ty, o.c);
    if (bv.ty == NEVER) {
        val missing = this.ir.unary(unop_ir::NOT, p.has, BOOL);
        return vnew(inner, this.ir.seq(nodes2(first, this.ir.if_(missing, bv.c, null)), p.value, inner));
    }
    val bc = try this.coerce(bv, inner, span);
    var r = vnew(inner, this.ir.seq(nodes(first), this.ir.node(ir_kind::COND(p.has, p.value, bc.c), inner), inner));
    merge_prov(&r, &av);
    merge_prov(&r, &bc);
    return r;
}

struct cond_code {
    test: u32;         // bool
    narrow: narrow?;   // a local narrowed inside
}

// condition of if/while: bool, or an optional (present?). A local optional gets narrowed.
attach fn cond(this: checker&, c: expr&) -> compile_error!cond_code {
    val v = try this.expr(c, BOOL);
    if (this.t.is_ptr(v.ty)) {
        // a pointer is true when it isn't null; a local T* narrows to a T& inside
        val test = this.ir.binary(binop_ir::NE, v.c, this.ir.node(ir_kind::NULLPTR, v.ty), BOOL);
        var n: narrow? = null;
        match (*this.t.get(v.ty)) {
            .PTR(inner) => {
                val key = this.place_key(c);
                if (v.lv && key != null) {
                    n = { key: key ?? "", l: { c: v.c, ty: this.t.ref_to(inner), mutable: v.mutable, orig_c: v.c, orig_ty: v.ty, ro: v.ro, via: v.via, root: v.root } };
                }
            },
            default => {},
        }
        return { test: test, narrow: n };
    }
    val inner = this.t.opt_inner(v.ty);
    if (inner) {
        val p = this.opt_parts(v.ty, v.c);
        var n: narrow? = null;
        val key = this.place_key(c);
        if (v.lv && key != null) {
            n = { key: key ?? "", l: { c: p.value, ty: inner, mutable: v.mutable, orig_c: v.c, orig_ty: v.ty, ro: v.ro, via: v.via, root: v.root } };
        }
        return { test: p.has, narrow: n };
    }
    val b = try this.coerce(v, BOOL, c.span);
    return { test: b.c, narrow: null };
}

// "x", "x.a.b", "this.next": places that narrowing can name
attach fn place_key(this: checker&, e: expr&) -> str? {
    var s: std::string = {};
    if (!place_key_into(e, &s)) {
        return null;
    }
    return this.intern(move s);
}

// appends e's place key to out; false when e isn't a nameable place
fn place_key_into(e: expr&, out: std::string&) -> bool {
    match (e.kind) {
        .PATH(p) => {
            if (!p.is_single()) {
                return false;
            }
            out.append(p.segs.at(0).name);
            return true;
        },
        .THIS => {
            out.append("this");
            return true;
        },
        .FIELD(b, n, gargs) => {
            if (gargs != null || !place_key_into(b, out)) {
                return false;
            }
            out.push('.');
            out.append(n);
            return true;
        },
        default => { return false; },
    }
}

// .value / .none on optionals, .err / .value on error unions
attach fn wrapper_field(this: checker&, b: tval&, name: str, span: span) -> compile_error!(tval?) {
    val loc = this.loc(span);
    match (*this.t.get(b.ty)) {
        .OPT(inner) => {
            if (name == "none") {
                val p = this.opt_parts(b.ty, b.c);
                var r = vnew(BOOL, this.ir.unary(unop_ir::NOT, p.has, BOOL));
                r.pure = b.pure;
                return r;
            }
            if (name != "value") {
                return null;
            }
            if (b.lv && (try this.needs_drop(inner))) {
                // a place: .value names the payload in place (a borrow), so ownership stays put
                val pt = this.t.ref_to(b.ty);
                val o = this.tmp_local("o", pt);
                val obj = this.ir.deref(o.c, b.ty);
                var stmts = nodes(this.ir.decl(o.id, this.ir.addr(b.c, pt)));
                val p = this.opt_parts(b.ty, obj);
                if (!this.opts.release) {
                    put(&stmts, this.ir.if_(this.ir.unary(unop_ir::NOT, p.has, BOOL), this.ir.panic("unwrapped a null value", loc), null));
                }
                val it = this.t.ref_to(inner);
                val at = this.ir.seq(move stmts, this.ir.addr(p.value, it), it);
                var r = vnew(inner, this.ir.deref(at, inner));
                r.lv = true;
                r.mutable = b.mutable;
                return r;
            }
            val o = this.tmp_local("o", b.ty);
            var stmts = nodes(this.ir.decl(o.id, b.c));
            val p = this.opt_parts(b.ty, o.c);
            if (!this.opts.release) {
                put(&stmts, this.ir.if_(this.ir.unary(unop_ir::NOT, p.has, BOOL), this.ir.panic("unwrapped a null value", loc), null));
            }
            return vnew(inner, this.ir.seq(move stmts, p.value, inner));
        },
        .ERR_UNION(e, t) => {
            if (name == "err") {
                val opt = this.t.opt_of(e);
                if (b.lv && (try this.needs_drop(e))) {
                    // a place: .err is a view of the error where it is (like .value), so ownership
                    // stays put and keeping it takes a copy
                    val pt = this.t.ref_to(b.ty);
                    val x = this.tmp_local("x", pt);
                    val obj = this.ir.deref(x.c, b.ty);
                    val o = this.tmp_local("eo", opt);
                    val some = this.some(vpure(e, this.ir.field(obj, 0, e)), opt).c;
                    val pick = this.ir.node(ir_kind::COND(this.nonzero(this.eu_code(b.ty, obj)), some, this.none(opt).c), opt);
                    val ot = this.t.ref_to(opt);
                    val at = this.ir.seq(nodes2(this.ir.decl(x.id, this.ir.addr(b.c, pt)), this.ir.decl(o.id, pick)), this.ir.addr(o.c, ot), ot);
                    var r = vnew(opt, this.ir.deref(at, opt));
                    r.lv = true;
                    r.pure = b.pure;
                    return r;
                }
                val x = this.tmp_local("x", b.ty);
                val code = this.eu_code(b.ty, x.c);
                val some = this.some(vpure(e, this.ir.field(x.c, 0, e)), opt).c;
                val none = this.none(opt).c;
                val pick = this.ir.node(ir_kind::COND(this.nonzero(code), some, none), opt);
                if (b.lv || t == VOID || !(try this.needs_drop(t))) {
                    return vnew(opt, this.ir.seq(nodes(this.ir.decl(x.id, b.c)), pick, opt));
                }
                // a temporary: the error moves out, and a value it held is deleted
                val r = this.tmp_local("r", opt);
                val d = try this.drop_fn(t);
                val drop_v = this.call_fn(d, nodes(this.ir.addr(this.ir.field(x.c, 1, t), this.t.ref_to(t))), VOID);
                var stmts = nodes2(this.ir.decl(x.id, b.c), this.ir.decl(r.id, pick));
                put(&stmts, this.ir.if_(this.ir.unary(unop_ir::NOT, this.nonzero(code), BOOL), drop_v, null));
                return vnew(opt, this.ir.seq(move stmts, r.c, opt));
            }
            if (name != "value" || t == VOID) {
                return null;
            }
            if (b.lv && (try this.needs_drop(t))) {
                // a place: .value names the payload in place (a borrow), so ownership stays put
                val pt = this.t.ref_to(b.ty);
                val x = this.tmp_local("x", pt);
                val obj = this.ir.deref(x.c, b.ty);
                var stmts = nodes(this.ir.decl(x.id, this.ir.addr(b.c, pt)));
                if (!this.opts.release) {
                    put(&stmts, this.ir.if_(this.nonzero(this.eu_code(b.ty, obj)), this.ir.panic("unwrapped an error", loc), null));
                }
                val tt = this.t.ref_to(t);
                val at = this.ir.seq(move stmts, this.ir.addr(this.ir.field(obj, 1, t), tt), tt);
                var r = vnew(t, this.ir.deref(at, t));
                r.lv = true;
                r.mutable = b.mutable;
                return r;
            }
            val x = this.tmp_local("x", b.ty);
            var stmts = nodes(this.ir.decl(x.id, b.c));
            if (!this.opts.release) {
                put(&stmts, this.ir.if_(this.nonzero(this.eu_code(b.ty, x.c)), this.ir.panic("unwrapped an error", loc), null));
            }
            return vnew(t, this.ir.seq(move stmts, this.ir.field(x.c, 1, t), t));
        },
        default => { return null; },
    }
}

// enum type that `.NAME` refers to, from the expected type
attach fn dot_target(this: checker&, want: u32?) -> u32? {
    val w = want ?? return null;
    match (*this.t.get(w)) {
        .ENUM(e) => { return w; },
        .OPT(i) => {
            if (this.enum_of(i) != null) {
                return i;
            }
        },
        .ERR_UNION(i, t) => {
            if (this.enum_of(i) != null) {
                return i;
            }
            if (this.enum_of(t) != null) {
                return t;
            }
        },
        default => {},
    }
    return null;
}

// `.NAME` or `.NAME(args)`: a variant of the enum the context expects
attach fn dot_variant(this: checker&, name: str, args: std::vec<expr>*, want: u32?, span: span) -> compile_error!tval {
    val t = this.dot_target(want) ?? return fail(span, fmt2("can't tell which enum .{} belongs to; write Enum::{}", S(name), S(name)));
    val eid = this.enum_of(t) ?? 0;
    val idx = this.variant_index(eid, name) ?? return fail(span, fmt2("{} has no variant {}", this.ty_name(t), S(name)));
    return this.make_variant(t, idx, args, span);
}
