// Expressions: literals, coercion, the expression switch and paths. Operators are in
// operators.volt, places and aggregates in places.volt, calls and builtins in calls.volt.
// A port of bootstrap/check/expr.rs; C text there is IR here.
use std::mem;

// a local of the ir fn being built: its index, and a place node for it
struct local_ref {
    id: u32; // index in the fn's locals
    c: u32;  // its place
}

// a new local of the fn being built
attach fn new_ir_local(this: checker&, name: str, t: u32) -> local_ref {
    val f = this.ir.fn_at(this.cx.irf);
    put(&f.locals, { name: name, ty: t });
    val id = @cast<u32>(f.locals.len - 1);
    return { id: id, c: this.ir.node(ir_kind::LOCAL(id), t) };
}

// a fresh temporary (_base7)
attach fn tmp_local(this: checker&, base: str, t: u32) -> local_ref {
    this.cx.next_id += 1;
    var n = S("_");
    n.append(base);
    n.append_uint(@cast<u64>(this.cx.next_id));
    return this.new_ir_local(this.intern(move n), t);
}

// statements, then c (a statement too when t is void/never)
attach fn wrap_pre(this: checker&, pre: std::vec<u32>, c: u32, t: u32) -> u32 {
    if (pre.len == 0) {
        return c;
    }
    var stmts = move pre;
    if (t == VOID || t == NEVER) {
        put(&stmts, c);
        return this.ir.seq(move stmts, null, t);
    }
    return this.ir.seq(move stmts, c, t);
}

attach fn vstmt(this: checker&, c: u32) -> tval {
    return vnew(VOID, c);
}

// an empty statement
attach fn nop(this: checker&) -> u32 {
    return this.ir.block({});
}

// a direct call of ir fn f, returning t
attach fn call_fn(this: checker&, f: u32, args: std::vec<u32>, t: u32) -> u32 {
    val fnode = this.ir.node(ir_kind::FN(f), VOIDPTR);
    return this.ir.call(fnode, move args, t);
}

// the innermost local called name, not looking past a barrier scope
attach fn lookup_local(this: checker&, name: str) -> local? {
    var i = this.cx.scopes.len;
    while (i > 0) {
        i -= 1;
        val s = this.cx.scopes.at(i);
        val l = s.vars.get(name);
        if (l) {
            return *l;
        }
        if (s.barrier) {
            break;
        }
    }
    return null;
}

// check e expecting type t, then convert it (an error if it can't)
attach fn expr_as(this: checker&, e: expr&, t: u32) -> compile_error!tval {
    val v = try this.expr(e, t);
    return this.coerce(v, t, e.span);
}

// Is this a pointer (or pointer-like optional) narrowed to non-null by if/while? The branch may
// assign it again (`cur = cur->next`), so the narrowing only holds when it is read.
attach fn narrow_recheck(this: checker&, l: local&) -> bool {
    if (l.orig_c == null) {
        return false;
    }
    if (this.t.is_ptr(l.orig_ty)) {
        return true;
    }
    val inner = this.t.opt_inner(l.orig_ty) ?? return false;
    return this.niche(inner);
}

// a local as a value. A narrowed pointer re-checks for null on each read in debug builds (a null
// one traps like `->` would); release builds don't check, like every raw pointer deref
attach fn local_val(this: checker&, l: local&, span: span) -> tval {
    var v = vpure(l.ty, l.c);
    v.lv = true;
    v.mutable = l.mutable;
    v.ro = l.ro;
    v.via = l.via;
    v.root = l.root;
    v.own = l.own;
    if (this.opts.release || !this.narrow_recheck(l)) {
        return v;
    }
    val pt = this.t.ref_to(l.ty);
    val q = this.tmp_local("nq", pt);
    var stmts: std::vec<u32> = {};
    put(&stmts, this.ir.decl(q.id, this.ir.addr(l.c, pt)));
    var cur = this.ir.deref(q.c, l.ty);
    val nf = this.niche_field(l.ty);
    if (nf) {
        cur = this.ir.field(cur, nf, this.field_ty(l.ty, nf)); // a box is null when its pointer is
    }
    put(&stmts, this.null_check(cur, span));
    v.c = this.ir.deref(this.ir.seq(move stmts, q.c, pt), l.ty);
    return v;
}

// if (p == null) panic("null pointer dereference")
attach fn null_check(this: checker&, p: u32, span: span) -> u32 {
    val t = this.ir.ty_of(p);
    val is_null = this.ir.binary(binop_ir::EQ, p, this.ir.node(ir_kind::NULLPTR, t), BOOL);
    return this.ir.if_(is_null, this.ir.panic("null pointer dereference", this.loc(span)), null);
}

// ---------- literals ----------

// an integer literal: the wanted type if it fits there (or is a float), else the first of i32,
// i64, i128 that holds it
attach fn int_lit(this: checker&, v: i128, want: u32?) -> tval {
    var t = I32;
    var chosen = false;
    if (want) {
        val w = want;
        val k = this.t.int_of(w);
        if ((k != null && (k ?? int_ty::I32).fits(v)) || this.t.is_float(w)) {
            t = w;
            chosen = true;
        }
    }
    if (!chosen) {
        if (int_ty::I32.fits(v)) {
            t = I32;
        } else if (int_ty::I64.fits(v)) {
            t = I64;
        } else {
            t = int_id(int_ty::I128);
        }
    }
    var r = vpure(t, this.ir.int(v, t));
    r.lit = lit::INT(v);
    return r;
}

// a float literal: the wanted float type, else f64
attach fn float_lit(this: checker&, v: f64, want: u32?) -> tval {
    var t = F64;
    if (want != null && this.t.is_float(want ?? 0)) {
        t = want ?? F64;
    }
    var r = vpure(t, this.ir.node(ir_kind::FLOAT(v), t));
    r.lit = lit::FLOAT(v);
    return r;
}

attach fn str_val(this: checker&, s: str) -> tval {
    var r = vpure(STR, this.ir.node(ir_kind::STR(s), STR));
    r.lit = lit::STR(s);
    return r;
}

// ---------- coercion ----------

// a never value (return, break, a panic...) typed as `to`, for a context that expects one
attach fn never_as(this: checker&, v: tval, to: u32) -> tval {
    if (to == VOID || to == NEVER) {
        var r = v;
        r.ty = to;
        return r;
    }
    val c = this.ir.seq(nodes2(v.c, this.ir.node(ir_kind::UNREACHABLE, NEVER)), this.ir.zero(to), to);
    return vnew(to, c);
}

// v wrapped in optional type opt (for a niche optional, like a pointer's, that's v itself)
attach fn some(this: checker&, v: tval, opt: u32) -> tval {
    val inner = this.t.opt_inner(opt) ?? VOID;
    if (this.niche(inner)) {
        var r = v;
        r.ty = opt;
        return r;
    }
    var inits: std::vec<field_init> = {};
    if (inner != VOID) {
        put(&inits, { field: 0, value: v.c });
    }
    put(&inits, { field: 1, value: this.ir.boolean(true) });
    var r = vnew(opt, this.ir.node(ir_kind::AGG(move inits), opt));
    r.pure = v.pure;
    r.ro = v.ro;
    r.via = v.via;
    r.root = v.root;
    return r;
}

// the empty value of optional type opt
attach fn none(this: checker&, opt: u32) -> tval {
    val inner = this.t.opt_inner(opt) ?? VOID;
    if (this.t.is_niche(inner)) {
        return vpure(opt, this.ir.node(ir_kind::NULLPTR, opt));
    }
    if (this.niche_field(inner) != null) {
        return vpure(opt, this.ir.zero(opt)); // the owning pointer null
    }
    var inits: std::vec<field_init> = {};
    put(&inits, { field: 1, value: this.ir.boolean(false) });
    return vpure(opt, this.ir.node(ir_kind::AGG(move inits), opt));
}

// a closure literal (not a stored closure)
attach fn is_closure_literal(this: checker&, v: tval&) -> bool {
    match (this.ir.at(v.c).kind) {
        .AGG(x) => {
            match (*this.t.get(v.ty)) {
                .CLOSURE(c) => { return true; },
                default => { return false; },
            }
        },
        default => { return false; },
    }
}

// can v convert to `to` implicitly (literals allowed to adapt)?
attach fn coercible(this: checker&, v: tval&, to: u32) -> bool {
    if (v.ty == to || v.ty == NEVER) {
        return true;
    }
    val tt = this.t.get(to);
    if (v.lit) {
        match (v.lit) {
            .INT(n) => {
                match (*tt) {
                    .INT(k) => { return k.fits(n) || v.wraps; },
                    .FLOAT(b) => { return true; },
                    default => {},
                }
            },
            .FLOAT(f) => {
                match (*tt) {
                    .FLOAT(b) => { return true; },
                    default => {},
                }
            },
            .STR(s) => {
                if (to == CSTR) {
                    return true;
                }
            },
        }
    }
    val ft = this.t.get(v.ty);
    match (*ft) {
        .INT(a) => {
            match (*tt) {
                .INT(b) => { return a.widens_to(b); },
                default => {},
            }
        },
        .FLOAT(a) => {
            match (*tt) {
                .FLOAT(b) => { return a <= b; },
                default => {},
            }
        },
        .NULL => {
            match (*tt) {
                .OPT(x) => { return true; },
                .PTR(x) => { return true; },
                .VOIDPTR => { return true; },
                default => {},
            }
        },
        default => {},
    }
    val inner = this.t.opt_inner(to);
    if (inner) {
        return this.coercible(v, inner);
    }
    match (*ft) {
        .REF(a) => {
            match (*tt) {
                .VOIDPTR => { return true; },
                .PTR(b) => { return a == b; },
                default => {},
            }
        },
        .PTR(a) => {
            if (to == VOIDPTR) {
                return true;
            }
        },
        .ARRAY(a, n) => {
            match (*tt) {
                .SLICE(b) => { return a == b && v.lv; },
                default => {},
            }
        },
        .STR => {
            match (*tt) {
                .SLICE(b) => { return b == U8; },
                default => {},
            }
        },
        .STRUCT(s) => {
            match (*tt) {
                .REF(t) => { return (this.box_inner(v.ty) ?? NO_TY) == t && v.lv; },
                .PTR(t) => { return (this.box_inner(v.ty) ?? NO_TY) == t && v.lv; },
                default => {},
            }
        },
        .CLOSURE(c) => {
            match (*tt) {
                .FN_VAL(ps&, r) => { return this.closure_sig_is(v.ty, ps, r) || this.generic_closure_takes(v.ty, ps.len); },
                default => {},
            }
        },
        default => {},
    }
    match (*tt) {
        .TRAIT_UNION(u) => { return this.union_member(to, v.ty) != null; },
        default => {},
    }
    return this.error_coercible(v, to);
}

// the same val as `to` (a conversion that keeps the code)
fn retyped(v: tval&, to: u32, c: u32) -> tval {
    var r = vnew(to, c);
    r.pure = v.pure;
    r.ro = v.ro;
    r.via = v.via;
    r.root = v.root;
    return r;
}

// v converted to type `to` by an implicit conversion (the ones coercible allows), or an error
attach fn coerce(this: checker&, v: tval, to: u32, span: span) -> compile_error!tval {
    if (v.ty == to) {
        return v;
    }
    if (v.ty == NEVER) {
        return this.never_as(v, to);
    }
    if (v.lit) {
        match (v.lit) {
            .INT(n) => {
                match (*this.t.get(to)) {
                    .INT(k) => {
                        if (!k.fits(n)) {
                            if (v.wraps) {
                                val w = wrap_bits(n, k.bits(), k.signed());
                                if (k.fits(w)) {
                                    return this.int_lit(w, to);
                                }
                                // a u128 past i128's range: the same bits, as a typed value
                                return vpure(to, this.ir.int(w, to));
                            }
                            return fail(span, fmt2("{} doesn't fit in {}", num(n), S(k.name())));
                        }
                        return this.int_lit(n, to);
                    },
                    .FLOAT(b) => { return this.float_lit(@cast<f64>(n), to); },
                    default => {},
                }
            },
            .FLOAT(f) => {
                match (*this.t.get(to)) {
                    .FLOAT(b) => { return this.float_lit(f, to); },
                    default => {},
                }
            },
            .STR(s) => {
                if (to == CSTR) {
                    for (b) in s {
                        if (b == 0) {
                            return fails(span, "this string has a \\0 inside, so it can't be a cstr");
                        }
                    }
                    var r = vpure(CSTR, this.ir.node(ir_kind::CSTR(s), CSTR));
                    r.lit = lit::STR(s);
                    return r;
                }
            },
        }
    }
    val ft = this.t.get(v.ty);
    val tt = this.t.get(to);
    match (*ft) {
        .INT(a) => {
            match (*tt) {
                .INT(b) => {
                    if (a.widens_to(b)) {
                        return retyped(&v, to, this.ir.conv(v.c, to));
                    }
                },
                default => {},
            }
        },
        .FLOAT(a) => {
            match (*tt) {
                .FLOAT(b) => {
                    if (a <= b) {
                        return retyped(&v, to, this.ir.conv(v.c, to));
                    }
                },
                default => {},
            }
        },
        .NULL => {
            match (*tt) {
                .OPT(x) => { return this.none(to); },
                .PTR(x) => { return vpure(to, this.ir.node(ir_kind::NULLPTR, to)); },
                .VOIDPTR => { return vpure(to, this.ir.node(ir_kind::NULLPTR, to)); },
                default => {},
            }
        },
        default => {},
    }
    val inner = this.t.opt_inner(to);
    if (inner != null && this.coercible(&v, inner ?? 0)) {
        val iv = try this.coerce(v, inner ?? 0, span);
        return this.some(iv, to);
    }
    match (*ft) {
        .REF(a) => {
            match (*tt) {
                .VOIDPTR => { return retyped(&v, to, this.ir.conv(v.c, to)); },
                .PTR(b) => {
                    if (a == b) {
                        return retyped(&v, to, v.c); // the same pointer
                    }
                },
                default => {},
            }
        },
        .PTR(a) => {
            if (to == VOIDPTR) {
                return retyped(&v, to, this.ir.conv(v.c, to));
            }
        },
        .ARRAY(a, n) => {
            match (*tt) {
                .SLICE(b) => {
                    if (a == b) {
                        if (!v.lv) {
                            return fails(span, "can't make a slice of a temporary array; store it in a variable first");
                        }
                        val pt = this.t.intern(tyk::PTR(a));
                        val first = this.ir.addr(this.ir.index(v.c, this.ir.int(0, USIZE), a), pt);
                        var inits: std::vec<field_init> = {};
                        put(&inits, { field: 0, value: first });
                        put(&inits, { field: 1, value: this.ir.int(@cast<i128>(n), USIZE) });
                        // the slice reaches the array, as &array would
                        this.note_mut(&v);
                        var r = retyped(&v, to, this.ir.node(ir_kind::AGG(move inits), to));
                        addr_prov(&r, &v);
                        return r;
                    }
                },
                default => {},
            }
        },
        .STR => {
            match (*tt) {
                .SLICE(b) => {
                    if (b == U8) {
                        val s = this.tmp_local("s", STR);
                        var inits: std::vec<field_init> = {};
                        put(&inits, { field: 0, value: this.ir.conv(this.ir.field(s.c, 0, this.t.intern(tyk::PTR(U8))), this.t.intern(tyk::PTR(U8))) });
                        put(&inits, { field: 1, value: this.ir.field(s.c, 1, USIZE) });
                        val agg = this.ir.node(ir_kind::AGG(move inits), to);
                        return retyped(&v, to, this.ir.seq(nodes(this.ir.decl(s.id, v.c)), agg, to));
                    }
                },
                default => {},
            }
        },
        .CLOSURE(c) => {
            match (*tt) {
                .FN_VAL(ps&, r) => {
                    val plain = this.closure_sig_is(v.ty, ps, r);
                    if (plain || this.generic_closure_takes(v.ty, ps.len)) {
                        // a closure literal lives to the end of the enclosing block
                        // ponytail: the fn value can still outlive a stored-away literal; a borrow check would catch it
                        if (!v.lv && !this.is_closure_literal(&v)) {
                            return fails(span, "a fn(...) value borrows its closure; store the closure in a variable first");
                        }
                        // a generic closure: its instance for these parameters
                        var body = c;
                        if (!plain) {
                            body = try this.closure_instance(c, ps, span);
                            if (this.ci(body).ret != r || !same_list(&this.ci(body).params, ps)) {
                                val got = this.t.intern(tyk::FN_VAL(copy this.ci(body).params, this.ci(body).ret));
                                return fail(span, fmt2("for these parameters this closure is a {}, not a {}", this.ty_name(got), this.ty_name(to)));
                            }
                        }
                        return retyped(&v, to, try this.closure_to_fn(&v, to, body));
                    }
                },
                default => {},
            }
        },
        .STRUCT(s) => {
            var target: u32? = null;
            match (*tt) {
                .REF(t) => { target = t; },
                .PTR(t) => { target = t; },
                default => {},
            }
            if (target != null && (this.box_inner(v.ty) ?? NO_TY) == (target ?? 0)) {
                if (!v.lv) {
                    return fail(span, fmt("this {} would be deleted right away; store it in a variable first", this.ty_name(v.ty)));
                }
                val o = this.owner(v.ty) ?? return fails(span, "");
                return retyped(&v, to, this.ir.field(v.c, o.index, to));
            }
        },
        default => {},
    }
    val m = this.union_member(to, v.ty);
    if (m) {
        val i = m;
        var inits: std::vec<field_init> = {};
        put(&inits, { field: 0, value: this.ir.int(@cast<i128>(i), int_id(int_ty::U16)) });
        put(&inits, { field: @cast<u32>(i) + 1, value: v.c });
        var r = vnew(to, this.ir.node(ir_kind::AGG(move inits), to));
        r.pure = v.pure;
        return r;
    }
    if (this.error_coercible(&v, to)) {
        return this.error_coerce(v, to, span);
    }
    return type_diff(fail(span, fmt2("expected {}, found {}", this.ty_name(to), this.ty_name(v.ty))));
}

// Make impure values temps (left to right) when more than one might have side effects, since C
// leaves argument/operand order unspecified. Returns statements to run first.
attach fn seq_vals(this: checker&, vals: std::vec<tval>&) -> std::vec<u32> {
    var impure: usize = 0;
    for (v&) in vals.items() {
        if (!v.pure && v.ty != VOID && v.ty != NEVER) {
            impure += 1;
        }
    }
    var pre: std::vec<u32> = {};
    if (impure < 2) {
        return pre;
    }
    for (v&) in vals.items() {
        if (!v.pure && v.ty != VOID && v.ty != NEVER) {
            val t = this.tmp_local("s", v.ty);
            put(&pre, this.ir.decl(t.id, v.c));
            v.c = t.c;
            v.pure = true;
        }
    }
    return pre;
}

// ---------- expressions ----------

// Check an expression and lower it to IR. want is the expected type, if known: literals, null
// and .VARIANT adapt to it, but callers still coerce the result.
attach fn expr(this: checker&, e: expr&, want: u32?) -> compile_error!tval {
    val span = e.span;
    // @typeinfo, comptime fn calls and comptime locals are evaluated now, not emitted
    if (this.is_ct_expr(e)) {
        val v = try this.ct_eval(e, want);
        if (this.opts.expand || this.opts.lsp) {
            val text = this.cval_text(&v);
            val r = try this.ct_to_val(move v, want, span);
            this.expanded(span, fmt2("= {} ({})", move text, this.ty_name(r.ty)));
            return r;
        }
        return this.ct_to_val(move v, want, span);
    }
    match (e.kind) {
        .INT(v) => {
            if (v > 170141183460469231731687303715884105727) {
                return fails(span, "number too large");
            }
            return this.int_lit(@cast<i128>(v), want);
        },
        .CHAR(v) => {
            var w = want;
            if (w == null) {
                if (v <= 255) {
                    w = U8;
                } else {
                    w = U32;
                }
            }
            return this.int_lit(@cast<i128>(v), w);
        },
        .FLOAT(v) => { return this.float_lit(v, want); },
        .STR(s) => {
            val v = this.str_val(s.as_str());
            if (want != null && (want ?? 0) == CSTR) {
                return this.coerce(v, CSTR, span);
            }
            return v;
        },
        .BOOL(b) => { return vpure(BOOL, this.ir.boolean(b)); },
        .NULL => {
            if (want != null && this.t.opt_inner(want ?? 0) != null) {
                return this.none(want ?? 0);
            }
            return vpure(NULL_TY, this.ir.node(ir_kind::NULLPTR, NULL_TY));
        },
        .PATH(p&) => { return this.path_expr(p, want, span); },
        .UNARY(op, x) => { return this.unary(op, x, want, span); },
        .BINARY(op, a, b) => { return this.binary(op, a, b, want, span); },
        .ASSIGN(op, l, r) => { return this.assign(op, l, r, span); },
        .INC_DEC(x, inc) => {
            val one = this.keep_expr({ kind: expr_kind::INT(1), span: span });
            if (inc) {
                return this.assign(binop::ADD, x, one, span);
            }
            return this.assign(binop::SUB, x, one, span);
        },
        .CAST(x, t&) => {
            val to = try this.resolve_type(t, this.cx.env);
            return this.cast(x, to, span);
        },
        .FIELD(base, name, gargs) => {
            if (gargs != null) {
                return fails(span, "generic methods need a call: x.f<T>()");
            }
            // a field narrowed by if/while
            val key = this.place_key(e);
            if (key) {
                val l = this.lookup_local(key);
                if (l) {
                    val lv = l;
                    return this.local_val(&lv, span);
                }
            }
            val b = try this.expr(base, null);
            // `if (val x = opt) a else |e| b` reads the hidden @if's error first: say what the
            // statement form says when there's no error to read
            if (name == "err") {
                var is_eu = false;
                match (*this.t.get(b.ty)) {
                    .ERR_UNION(x, y) => { is_eu = true; },
                    default => {},
                }
                match (base.kind) {
                    .PATH(p) => {
                        if (!is_eu && p.is_single() && p.segs.at(0).name == IF_TMP) {
                            val text = this.files.at(@cast<usize>(span.file)).text;
                            var cap = "e";
                            if (span.hi <= text.len && span.lo < span.hi) {
                                cap = text[@cast<usize>(span.lo)..@cast<usize>(span.hi)];
                            }
                            return fail(span, fmt2("else |{}| needs an error union, found {}", S(cap), this.ty_name(b.ty)));
                        }
                    },
                    default => {},
                }
            }
            return this.field(b, name, span);
        },
        .INDEX(base, idx) => { return this.index(base, idx, span); },
        .CALL(callee, args&) => { return this.call(callee, args, want, span); },
        .BUILTIN(name, gargs&, args&) => { return this.builtin(name, gargs, ptr_of(args), want, span); },
        .TUPLE(elems&) => { return this.tuple(elems, want, span); },
        .LITERAL(entries&) => { return this.literal(entries, want, span); },
        .REPEAT(x, n) => { return this.repeat(x, n, want, span); },
        .RANGE(lo&, hi&, incl) => { return this.range_val(ptr_box(lo), ptr_box(hi), incl, want, span); },
        .RETURN(v&) => { return this.ret(ptr_box(v), span); },
        .BREAK(label, v&) => { return this.brk(label, ptr_box(v), span); },
        .CONTINUE(label) => { return this.cont(label, span); },
        .BLOCK(label, b&) => { return this.block_expr(label, b, want, span); },
        .LOOP(label, b&) => { return this.loop_expr(label, b, want, span); },
        .WHILE(label, cond, b&) => { return this.while_expr(label, cond, b, span); },
        .FOR(f) => { return this.for_expr(f, want, span); },
        .IF(n&) => {
            if (n.is_comptime) {
                // only the branch that's taken gets checked
                val c = try this.ct_eval(n.cond, BOOL);
                var taken = false;
                match (c) {
                    .BOOL(b) => { taken = b; },
                    default => { return fails(n.cond.span, "comptime if needs a bool"); },
                }
                if (taken) {
                    this.expanded(n.cond.span, S("comptime if: true, this branch"));
                } else {
                    this.expanded(n.cond.span, S("comptime if: false, the else"));
                }
                if (taken) {
                    val bc = try this.block_code(&n.then);
                    if (bc.div) {
                        return vnew(NEVER, bc.c);
                    }
                    return vnew(VOID, bc.c);
                }
                if (n.els) {
                    return this.expr(n.els, want);
                }
                return this.vstmt(this.nop());
            }
            return this.if_expr(n.cond, &n.then, ptr_box(&n.els), span);
        },
        .MOVE(x) => {
            val v = try this.expr(x, want);
            return this.take(v, span);
        },
        .COPY(x) => {
            val v = try this.expr(x, want);
            return this.copy_val(v, span);
        },
        .ERROR_ANY => { return vpure(ANYERR, this.ir.int(1, ANYERR)); },
        .THIS => {
            // a local like any other: a by-value this moves (and can't be used after), as a param would
            this.lookup_local("this") ?? return fails(span, "no 'this' here (static functions don't have one)");
            val p = single_path("this", span);
            return this.path_expr(&p, want, span);
        },
        .DOT_VARIANT(n) => { return this.dot_variant(n, null, want, span); },
        .TRY(x) => { return this.try_expr(x, span); },
        .CATCH(x, cap&, h) => { return this.catch_expr(x, ptr_of(cap), h, span); },
        .OR_ELSE(a, b) => { return this.orelse(a, b, span); },
        .MATCH(m&) => {
            if (m.is_comptime) {
                return this.ct_match(m.scrut, &m.arms, want, span);
            }
            return this.match_expr(m.scrut, &m.arms, want, span);
        },
        .CLOSURE(c&) => { return this.closure_expr(c, want, span); },
        .AWAIT(x) => { return this.await_expr(x, want); },
        .ASYNC(x) => { return fails(span, "async f() builds a frame in place, so it only works as `val fr = async f()`"); },
        .QUOTE(p) => { return fails(span, "a quote is evaluated at compile time"); },
        .TYPE_BODY(b) => {
            if (b.is_enum) {
                return fails(span, "enum { } makes a type, a value only at compile time: return it from a comptime fn or name it with type name = enum { ... };");
            }
            return fails(span, "struct { } makes a type, a value only at compile time: return it from a comptime fn or name it with type name = struct { ... };");
        },
    }
}

// the expr inside an optional box, by pointer (null when absent)
fn ptr_box(o: std::box<expr>?&) -> expr* {
    if ((*o).none) {
        return null;
    }
    return (*o).value.ptr;
}

// a name as a value: a local, a generic value param, a global, a fn (a fn value, or a C fn
// pointer where one is wanted) or Type::member
attach fn path_expr(this: checker&, p: path&, want: u32?, span: span) -> compile_error!tval {
    if (p.is_single()) {
        val name = p.segs.at(0).name;
        val lo = this.lookup_local(name);
        if (lo) {
            val l = lo;
            if (this.opts.lsp) {
                this.lsp_local_use(l.orig_c ?? l.c, name, l.ty, span);
            }
            if (this.narrow_recheck(&l)) {
                return this.local_val(&l, span);
            }
            if (this.cx.moved.has(l.c)) {
                val e = fail(span, fmt("'{}' was moved earlier (by move, an assignment, an argument or a return), so it can't be used here", S(name)));
                val at = this.cx.move_sites.get(l.c);
                if (at) {
                    return with_label(move e, *at, S("moved here"));
                }
                return e;
            }
            this.read_view(&l, span);
            var v = vpure(l.ty, l.c);
            v.lv = true;
            v.mutable = l.mutable;
            v.ro = l.ro;
            v.via = l.via;
            v.root = l.root;
            v.own = l.own;
            val ln = this.cx.loans.get(l.c);
            if (ln) {
                v.loan = ln->owner;
                v.loan_name = ln->owner_name;
            }
            if (l.flag != null) {
                v.owner = name;
            }
            return v;
        }
        val g = this.env_generic(this.cx.env, name);
        if (g) {
            match (g) {
                .INT(v) => { return this.int_lit(v, want); },
                .STR(s) => {
                    val v = this.str_val(s);
                    if (want != null && (want ?? 0) == CSTR) {
                        return this.coerce(v, CSTR, span);
                    }
                    return v;
                },
                default => {},
            }
        }
    }
    val ns = this.env_at(this.cx.env).ns;
    var f: found? = null;
    if (p.segs.len == 1) {
        f = this.lookup(ns, p.segs.at(0).name);
    } else {
        f = this.lookup_path_ns(ns, p);
    }
    if (f == null) {
        val m = try this.member_path(p);
        if (m) {
            match (m) {
                .OF(t, mem) => { return this.type_member_value(t, mem, null, span); },
                .GENERIC_ENUM(d, mem) => {
                    val t = try this.infer_enum(d, mem, null, want, span);
                    return this.type_member_value(t, mem, null, span);
                },
            }
        }
        return this.unknown(span, "name", ns, p, true);
    }
    match (f ?? found::NS(0)) {
        .DECLS(l) => {
            val ds = this.list(l);
            val d = *ds.at(0);
            try this.visible(d, span);
            val many = ds.len > 1;
            match (this.item_of(d).kind) {
                .GLOBAL(x) => {
                    val g = try this.global(d, span);
                    if (this.opts.lsp) {
                        this.lsp_decl_use(d, p.last(), span, fmt2("{}: {}", S(p.last()), this.ty_name(g.ty)));
                    }
                    var v = vpure(g.ty, g.c);
                    v.lv = true;
                    v.mutable = g.mutable;
                    return v;
                },
                .FN(fd) => {
                    if (many) {
                        return fail(span, fmt("'{}' is overloaded, so it can't be used as a value here", S(fd.name)));
                    }
                    // f<Args>: that instance (generic args bound as in a call with none to infer from)
                    var binds: std::vec<gval> = {};
                    val last = p.segs.at(p.segs.len - 1);
                    if (last.args) {
                        var unknown: std::vec<tval?> = {};
                        for (pa&) in fd.params.items() {
                            if (pa.name != "this") {
                                put(&unknown, null);
                            }
                        }
                        val b = try this.bind_cand(d, null, null, &last.args, &unknown);
                        match (b) {
                            .OK(bs, x) => { binds = copy bs; },
                            .NO(r) => { return fail(span, copy r); },
                        }
                    }
                    val i = try this.fn_inst(d, move binds, span);
                    this.use_fn(i);
                    if (this.opts.lsp) {
                        this.lsp_fn_use(d, i, span);
                    }
                    var ps: std::vec<u32> = {};
                    for (pi&) in this.fi(i).params.items() {
                        put(&ps, pi.ty);
                    }
                    val ret = this.fi(i).ret;
                    val va = this.fi(i).c_varargs;
                    // an optional C fn pointer (a C callback param) wants the thin pointer too
                    var w = want;
                    if (w) {
                        val oi = this.t.opt_inner(w);
                        if (oi) {
                            w = oi;
                        }
                    }
                    var wants_ptr = false;
                    if (w) {
                        match (*this.t.get(w)) {
                            .FN_PTR(a, b, c) => { wants_ptr = true; },
                            .VOIDPTR => { wants_ptr = true; },
                            .PTR(x) => { wants_ptr = true; },
                            default => {},
                        }
                    }
                    if (wants_ptr || va) {
                        // extern "C" fn(...), or a raw pointer (@cast<void*>(f)): a plain C function
                        // pointer
                        val t = this.t.intern(tyk::FN_PTR(move ps, ret, va));
                        this.escape(body_key(BODY_FN, i), t);
                        return vpure(t, this.ir.node(ir_kind::FN(this.fi(i).ir), t));
                    }
                    val t = this.t.intern(tyk::FN_VAL(move ps, ret));
                    this.escape(body_key(BODY_FN, i), t);
                    return vpure(t, this.fn_value(i, t));
                },
                default => { return fail(span, fmt("'{}' is a type, not a value", S(p.last()))); },
            }
        },
        .NS(n) => { return fail(span, fmt("'{}' is a namespace, not a value", S(p.last()))); },
    }
}

// Type::member as a value, or called with args
attach fn type_member_value(this: checker&, t: u32, mem: str, args: std::vec<expr>*, span: span) -> compile_error!tval {
    val eid = this.enum_of(t);
    if (eid) {
        val idx = this.variant_index(eid, mem);
        if (idx) {
            return this.make_variant(t, idx, args, span);
        }
    }
    return fail(span, fmt2("{} has no member '{}'", this.ty_name(t), S(mem)));
}
