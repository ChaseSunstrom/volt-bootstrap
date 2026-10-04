// Operators: unary, binary (checked integer arithmetic, pointer arithmetic, shifts,
// comparisons), assignment and casts. A port of bootstrap/check/operators.rs.
use std::mem;

// ---------- operators ----------

// -x, !x, ~x, &x and *x. In debug builds negating an integer traps on overflow and *p checks a raw
// pointer for null.
attach fn unary(this: checker&, op: unop, x: expr&, want: u32?, span: span) -> compile_error!tval {
    match (op) {
        .NEG => {
            val v = try this.expr(x, want);
            if (v.lit) {
                match (v.lit) {
                    .INT(n) => {
                        var w = want;
                        if (w == null) {
                            w = v.ty;
                        }
                        return this.int_lit(0 -% n, w);
                    },
                    .FLOAT(f) => { return this.float_lit(-f, v.ty); },
                    default => {},
                }
            }
            match (*this.t.get(v.ty)) {
                .FLOAT(b) => {
                    var r = vnew(v.ty, this.ir.unary(unop_ir::NEG, v.c, v.ty));
                    r.pure = v.pure;
                    return r;
                },
                .INT(k) => {
                    if (k.signed()) {
                        if (this.opts.release) {
                            return vnew(v.ty, this.ir.unary(unop_ir::NEG, v.c, v.ty));
                        }
                        val c = this.ir.node(ir_kind::CHECKED(binop_ir::SUB, this.ir.int(0, v.ty), v.c, this.loc(span)), v.ty);
                        return vnew(v.ty, c);
                    }
                },
                default => {},
            }
            return fail(span, fmt("can't negate a {}", this.ty_name(v.ty)));
        },
        .NOT => {
            val v = try this.expr_as(x, BOOL);
            var r = vnew(BOOL, this.ir.unary(unop_ir::NOT, v.c, BOOL));
            r.pure = v.pure;
            return r;
        },
        .BITNOT => {
            val v = try this.expr(x, want);
            if (this.t.int_of(v.ty) == null) {
                return fail(span, fmt("~ needs an integer, found {}", this.ty_name(v.ty)));
            }
            var r = vnew(v.ty, this.ir.unary(unop_ir::BITNOT, v.c, v.ty));
            r.pure = v.pure;
            return r;
        },
        .ADDR => {
            val v = try this.expr(x, null);
            if (!v.lv) {
                return fails(span, "can't take the address of a temporary value; store it in a variable first");
            }
            val t = this.t.ref_to(v.ty);
            var r = vnew(t, this.ir.addr(v.c, t));
            r.pure = v.pure;
            this.note_mut(&v);
            addr_prov(&r, &v);
            return r;
        },
        .DEREF => {
            val v = try this.expr(x, null);
            val o = this.owner(v.ty);
            if (o) {
                val oi = o;
                val pt = this.t.intern(tyk::PTR(oi.inner));
                var r = vnew(oi.inner, this.ir.deref(this.ir.field(v.c, oi.index, pt), oi.inner));
                r.lv = true;
                r.mutable = true;
                r.pure = v.pure;
                return r;
            }
            match (*this.t.get(v.ty)) {
                .REF(t) => {
                    var r = vnew(t, this.ir.deref(v.c, t));
                    r.lv = true;
                    r.mutable = true;
                    r.pure = v.pure;
                    through(&r, v);
                    return r;
                },
                .PTR(t) => {
                    // a raw pointer may be null: debug builds check, like bounds
                    var c = this.ir.deref(v.c, t);
                    if (!this.opts.release) {
                        val np = this.tmp_local("np", v.ty);
                        val chk = this.null_check(np.c, span);
                        c = this.ir.deref(this.ir.seq(nodes2(this.ir.decl(np.id, v.c), chk), np.c, v.ty), t);
                    }
                    var r = vnew(t, c);
                    r.lv = true;
                    r.mutable = true;
                    r.pure = v.pure;
                    through(&r, v);
                    return r;
                },
                .VOIDPTR => { return fails(span, "can't dereference a void*; @cast it to a typed pointer first"); },
                .OPT(t) => { return fails(span, "this pointer might be null; check it with if or ?? first"); },
                default => { return fail(span, fmt("can't dereference a {}", this.ty_name(v.ty))); },
            }
        },
    }
}

// Bring two operands to one type: literals adapt, then lossless widening.
attach fn unify(this: checker&, a: tval, b: tval, span: span) -> compile_error!(a: tval, b: tval) {
    if (a.ty == b.ty) {
        return { a: a, b: b };
    }
    if (a.lit != null && b.lit == null && this.coercible(&a, b.ty)) {
        return { a: try this.coerce(a, b.ty, span), b: b };
    }
    if (b.lit != null && this.coercible(&b, a.ty)) {
        return { a: a, b: try this.coerce(b, a.ty, span) };
    }
    if (this.coercible(&a, b.ty) && this.t.opt_inner(b.ty) == null) {
        return { a: try this.coerce(a, b.ty, span), b: b };
    }
    if (this.coercible(&b, a.ty) && this.t.opt_inner(a.ty) == null) {
        return { a: a, b: try this.coerce(b, a.ty, span) };
    }
    return type_diff(fail(span, fmt2("mismatched types {} and {}", this.ty_name(a.ty), this.ty_name(b.ty))));
}

fn is_cmp_op(op: binop) -> bool {
    match (op) {
        .EQ => { return true; },
        .NE => { return true; },
        .LT => { return true; },
        .GT => { return true; },
        .LE => { return true; },
        .GE => { return true; },
        default => { return false; },
    }
}

fn cmp_ir(op: binop) -> binop_ir {
    match (op) {
        .EQ => { return binop_ir::EQ; },
        .NE => { return binop_ir::NE; },
        .LT => { return binop_ir::LT; },
        .GT => { return binop_ir::GT; },
        .LE => { return binop_ir::LE; },
        default => { return binop_ir::GE; },
    }
}

fn cmp_sym(op: binop) -> str {
    match (op) {
        .EQ => { return "=="; },
        .NE => { return "!="; },
        .LT => { return "<"; },
        .GT => { return ">"; },
        .LE => { return "<="; },
        default => { return ">="; },
    }
}

// == and != on a struct (or an enum with payloads) call its eq(other: T&): one written for it, or a
// derive's (std::compare's, for any type, is == itself, so it doesn't count). null: it has none
attach fn eq_call(this: checker&, op: binop, a: tval, ae: expr&, be: expr&, span: span) -> compile_error!(tval?) {
    var own_type = false;
    match (*this.t.get(a.ty)) {
        .STRUCT(s) => { own_type = true; },
        .ENUM(e) => { own_type = this.ei(e).has_payload; },
        default => {},
    }
    if (!own_type) {
        return null;
    }
    // probed with another of the same type, as == compares
    var probe: std::vec<tval?> = {};
    put(&probe, vpure(this.t.ref_to(a.ty), this.ir.boolean(false)));
    var fits: std::vec<u32> = {};
    var none: std::vec<garg> = {};
    for (d&) in this.named(&this.attached, "eq").items() {
        if (this.blanket_positions(*d) == 0) {
            match (try this.bind_cand(*d, &a, null, &none, &probe)) {
                .OK(b, j) => { put(&fits, *d); },
                default => {},
            }
        }
    }
    if (fits.len == 0) {
        return null;
    }
    // eq takes other by reference: a place's address. A temporary goes in this's place, which may be
    // one (it lives to the end of the statement), so with a temporary on the right the left goes
    // second: only a variable or a field of one (it reads the same either way)
    var args: std::vec<expr> = {};
    var v: tval = a;
    if (is_place(be)) {
        put(&args, { kind: expr_kind::UNARY(unop::ADDR, bx(copy *be)), span: be.span });
        v = try this.resolve_call("eq", &fits, a, null, &none, &args, BOOL, span);
    } else if (is_plain_place(ae)) {
        val b = try this.expr(be, a.ty);
        put(&args, { kind: expr_kind::UNARY(unop::ADDR, bx(copy *ae)), span: ae.span });
        v = try this.resolve_call("eq", &fits, b, null, &none, &args, BOOL, span);
    } else {
        return fail(span, fmt("== on two temporary {}s: store one in a variable first", this.ty_name(a.ty)));
    }
    if (op == binop::NE) {
        var r = vnew(BOOL, this.ir.unary(unop_ir::NOT, v.c, BOOL));
        r.pure = v.pure;
        return r;
    }
    return v;
}

// a place whose address can be taken: a variable, this, *p, or a field or element of a place
fn is_place(e: expr&) -> bool {
    match (e.kind) {
        .PATH(p) => { return true; },
        .THIS => { return true; },
        .FIELD(b, n, g) => { return g == null && is_place(b); },
        .INDEX(b, i) => { return is_place(b); },
        .UNARY(o, x) => { return o == unop::DEREF; },
        .BUILTIN(n, g, a&) => {
            val ap = ptr_of(a);
            if (n != "field" || ap == null || ap->len == 0) {
                return false;
            }
            match (*ap->at(0)) {
                .EXPR(b&) => { return is_place(b); },
                default => { return false; },
            }
        },
        default => { return false; },
    }
}

// a place reading which runs nothing: a variable, this, a field of one, or an element at a variable
// or literal index
fn is_plain_place(e: expr&) -> bool {
    match (e.kind) {
        .PATH(p) => { return true; },
        .THIS => { return true; },
        .FIELD(b, n, g) => { return g == null && is_plain_place(b); },
        .INDEX(b, i) => {
            match (i.kind) {
                .PATH(p) => { return is_plain_place(b); },
                .INT(v) => { return is_plain_place(b); },
                default => { return false; },
            }
        },
        .BUILTIN(n, g, a&) => {
            val ap = ptr_of(a);
            if (n != "field" || ap == null || ap->len == 0) {
                return false;
            }
            match (*ap->at(0)) {
                .EXPR(b&) => { return is_plain_place(b); },
                default => { return false; },
            }
        },
        default => { return false; },
    }
}

// Binary operators. The right operand is checked expecting the left's type (so literals adapt),
// integer constants fold, and integer arithmetic traps on overflow in debug builds.
attach fn binary(this: checker&, op: binop, ae: expr&, be: expr&, want: u32?, span: span) -> compile_error!tval {
    if (op == binop::AND || op == binop::OR) {
        val a = try this.expr_as(ae, BOOL);
        val b = try this.expr_as(be, BOOL);
        var o = binop_ir::AND;
        if (op == binop::OR) {
            o = binop_ir::OR;
        }
        var r = vnew(BOOL, this.ir.binary(o, a.c, b.c, BOOL));
        r.pure = a.pure && b.pure;
        return r;
    }
    val is_cmp = is_cmp_op(op);
    // a numeric expected type guides the operands of arithmetic (a comparison's result says nothing)
    var operand_want: u32? = null;
    if (!is_cmp && want != null) {
        val w = want ?? 0;
        if (this.t.int_of(w) != null || this.t.is_float(w)) {
            operand_want = w;
        }
    }
    val a = try this.expr(ae, operand_want);
    var b_want: u32? = a.ty;
    var be_null = false;
    match (be.kind) {
        .NULL => { be_null = true; },
        default => {},
    }
    if ((op == binop::EQ || op == binop::NE) && !be_null) {
        val called = try this.eq_call(op, a, ae, be, span);
        if (called) {
            return called;
        }
    }
    if (be_null || a.lit != null || a.ty == NULL_TY) {
        b_want = operand_want;
    }
    val b = try this.expr(be, b_want);
    if (!is_cmp) {
        val pa = try this.pointer_arith(op, a, b, span);
        if (pa) {
            return pa;
        }
    }
    if (op == binop::SHL || op == binop::SHR) {
        return this.shift(op, a, b, span);
    }
    // fold constants
    if (a.lit != null && b.lit != null) {
        var x: i128 = 0;
        var y: i128 = 0;
        var both = false;
        match (a.lit ?? lit::STR("")) {
            .INT(n) => {
                match (b.lit ?? lit::STR("")) {
                    .INT(m) => {
                        x = n;
                        y = m;
                        both = true;
                    },
                    default => {},
                }
            },
            default => {},
        }
        if (both) {
            var r: i128? = null;
            match (op) {
                .ADD => { r = add_i128(x, y); },
                .WADD => { r = add_i128(x, y); },
                .SUB => { r = sub_i128(x, y); },
                .WSUB => { r = sub_i128(x, y); },
                .MUL => { r = mul_i128(x, y); },
                .WMUL => { r = mul_i128(x, y); },
                .DIV => { r = div_i128(x, y); },
                .REM => { r = rem_i128(x, y); },
                .BITAND => { r = x & y; },
                .BITOR => { r = x | y; },
                .BITXOR => { r = x ^ y; },
                default => {},
            }
            if (r) {
                var t = want;
                if (a.ty == b.ty) {
                    t = a.ty;
                }
                var w = want;
                if (w == null) {
                    w = t;
                }
                return this.int_lit(r, w);
            }
            if (!is_cmp) {
                return fails(span, "constant overflow or division by zero");
            }
        }
    }
    if (is_cmp) {
        return this.compare(op, a, b, span);
    }
    val u = try this.unify(a, b, span);
    val t = u.a.ty;
    var pair: std::vec<tval> = {};
    put(&pair, u.a);
    put(&pair, u.b);
    val pre = this.seq_vals(&pair);
    val av = *pair.at(0);
    val bv = *pair.at(1);
    var c: u32 = 0;
    match (*this.t.get(t)) {
        .INT(k) => { c = try this.int_arith(op, k, av.c, bv.c, span, t); },
        .FLOAT(fb) => {
            var o = binop_ir::ADD;
            match (op) {
                .ADD => { o = binop_ir::ADD; },
                .WADD => { o = binop_ir::ADD; },
                .SUB => { o = binop_ir::SUB; },
                .WSUB => { o = binop_ir::SUB; },
                .MUL => { o = binop_ir::MUL; },
                .WMUL => { o = binop_ir::MUL; },
                .DIV => { o = binop_ir::DIV; },
                .REM => { o = binop_ir::REM; },
                default => { return fail(span, fmt("{} doesn't work on floats", S(binop_text(op)))); },
            }
            c = this.ir.binary(o, av.c, bv.c, t);
        },
        default => { return fail(span, fmt2("can't use {} on {}", S(binop_text(op)), this.ty_name(t))); },
    }
    var r = vnew(t, this.wrap_pre(move pre, c, t));
    r.pure = av.pure && bv.pure && this.opts.release;
    return r;
}

// p + n, p - n (scaled by the element size, like C) and p - q; other arithmetic on pointers is an error
attach fn pointer_arith(this: checker&, op: binop, a: tval, b: tval, span: span) -> compile_error!(tval?) {
    for (k) in 0..2 {
        var t = a.ty;
        if (k == 1) {
            t = b.ty;
        }
        match (*this.t.get(t)) {
            .REF(x) => { return fails(span, "can't do arithmetic on a reference (T&); a pointer (T*) can"); },
            .VOIDPTR => { return fails(span, "can't do arithmetic on a void*; @cast it to a typed pointer first"); },
            default => {},
        }
    }
    var ap = false;
    var bp = false;
    match (*this.t.get(a.ty)) {
        .PTR(x) => { ap = true; },
        default => {},
    }
    match (*this.t.get(b.ty)) {
        .PTR(x) => { bp = true; },
        default => {},
    }
    if (!ap && !bp) {
        return null;
    }
    if (ap && bp && op == binop::SUB) {
        if (a.ty != b.ty) {
            return type_diff(fail(span, fmt2("mismatched types {} and {}", this.ty_name(a.ty), this.ty_name(b.ty))));
        }
        var pair: std::vec<tval> = {};
        put(&pair, a);
        put(&pair, b);
        val pre = this.seq_vals(&pair);
        val isz = int_id(int_ty::ISIZE);
        val c = this.ir.binary(binop_ir::SUB, pair.at(0).c, pair.at(1).c, isz);
        return vnew(isz, this.wrap_pre(move pre, c, isz));
    }
    if (!ap && bp && op == binop::ADD) {
        return this.pointer_arith(op, b, a, span); // n + p is p + n, like C
    }
    if (ap && !bp && (op == binop::ADD || op == binop::SUB)) {
        var bb = b;
        if (b.lit != null) {
            bb = try this.coerce(b, int_id(int_ty::ISIZE), span);
        }
        if (this.t.int_of(bb.ty) == null) {
            return fail(span, fmt("a pointer moves by an integer, found {}", this.ty_name(bb.ty)));
        }
        val t = a.ty;
        var pair: std::vec<tval> = {};
        put(&pair, a);
        put(&pair, bb);
        val pre = this.seq_vals(&pair);
        var o = binop_ir::ADD;
        if (op == binop::SUB) {
            o = binop_ir::SUB;
        }
        val c = this.ir.binary(o, pair.at(0).c, pair.at(1).c, t);
        return vnew(t, this.wrap_pre(move pre, c, t));
    }
    return fails(span, "pointers only add or subtract an integer (p + n, p - n), or subtract a pointer (p - q)");
}

// the smallest value of a signed int type
fn int_min(k: int_ty) -> i128 {
    if (k.bits() == 128) {
        return -170141183460469231731687303715884105727 - 1;
    }
    return 0 - (@cast<i128>(1) << (k.bits() - 1));
}

// An integer operation on a and b, of type t. Debug builds trap when +, -, * overflow (CHECKED
// nodes) and when / or % divides by zero or overflows (MIN / -1); the wrapping ops (+%, -%, *%) wrap.
attach fn int_arith(this: checker&, op: binop, k: int_ty, a: u32, b: u32, span: span, t: u32) -> compile_error!u32 {
    var o = binop_ir::ADD;
    match (op) {
        .ADD => { o = binop_ir::ADD; },
        .WADD => { o = binop_ir::ADD; },
        .SUB => { o = binop_ir::SUB; },
        .WSUB => { o = binop_ir::SUB; },
        .MUL => { o = binop_ir::MUL; },
        .WMUL => { o = binop_ir::MUL; },
        .DIV => { o = binop_ir::DIV; },
        .REM => { o = binop_ir::REM; },
        .BITAND => { o = binop_ir::BITAND; },
        .BITOR => { o = binop_ir::BITOR; },
        .BITXOR => { o = binop_ir::BITXOR; },
        default => { return fails(span, "bad operator"); },
    }
    val checked_arith = op == binop::ADD || op == binop::SUB || op == binop::MUL;
    if (checked_arith && !this.opts.release) {
        return this.ir.node(ir_kind::CHECKED(o, a, b, this.loc(span)), t);
    }
    if ((op == binop::DIV || op == binop::REM) && !this.opts.release) {
        val loc = this.loc(span);
        val ta = this.tmp_local("a", t);
        val tb = this.tmp_local("b", t);
        var stmts: std::vec<u32> = {};
        put(&stmts, this.ir.decl(ta.id, a));
        put(&stmts, this.ir.decl(tb.id, b));
        val zero = this.ir.binary(binop_ir::EQ, tb.c, this.ir.int(0, t), BOOL);
        put(&stmts, this.ir.if_(zero, this.ir.panic("division by zero", loc), null));
        if (k.signed()) {
            val m1 = this.ir.binary(binop_ir::EQ, tb.c, this.ir.int(-1, t), BOOL);
            val mn = this.ir.binary(binop_ir::EQ, ta.c, this.ir.int(int_min(k), t), BOOL);
            put(&stmts, this.ir.if_(this.ir.binary(binop_ir::AND, m1, mn, BOOL), this.ir.panic("integer overflow", loc), null));
        }
        return this.ir.seq(move stmts, this.ir.binary(o, ta.c, tb.c, t), t);
    }
    return this.ir.binary(o, a, b, t);
}

// a << b, a >> b; debug builds trap when b is at least a's bit width
attach fn shift(this: checker&, op: binop, a: tval, b: tval, span: span) -> compile_error!tval {
    val k = this.t.int_of(a.ty) ?? return fail(span, fmt("can't shift a {}", this.ty_name(a.ty)));
    var bb = b;
    if (b.lit != null) {
        bb = try this.coerce(b, U32, span);
    }
    if (this.t.int_of(bb.ty) == null) {
        return fails(span, "shift amount must be an integer");
    }
    var o = binop_ir::SHL;
    if (op == binop::SHR) {
        o = binop_ir::SHR;
    }
    if (this.opts.release) {
        return vnew(a.ty, this.ir.binary(o, a.c, bb.c, a.ty));
    }
    val ta = this.tmp_local("a", a.ty);
    val u64t = int_id(int_ty::U64);
    val ts = this.tmp_local("s", u64t);
    var stmts: std::vec<u32> = {};
    put(&stmts, this.ir.decl(ta.id, a.c));
    put(&stmts, this.ir.decl(ts.id, this.ir.conv(bb.c, u64t)));
    val big = this.ir.binary(binop_ir::GE, ts.c, this.ir.int(@cast<i128>(k.bits()), u64t), BOOL);
    put(&stmts, this.ir.if_(big, this.ir.panic("shift amount too large", this.loc(span)), null));
    return vnew(a.ty, this.ir.seq(move stmts, this.ir.binary(o, ta.c, ts.c, a.ty), a.ty));
}

// Comparisons: a pointer or optional against null, then numbers, pointers, bools, strs, errors and
// plain enums (only numbers and pointers are ordered).
attach fn compare(this: checker&, op: binop, a: tval, b: tval, span: span) -> compile_error!tval {
    val sym = cmp_sym(op);
    val eqne = op == binop::EQ || op == binop::NE;
    // optional or pointer vs null
    for (k) in 0..2 {
        var x = a;
        var y = b;
        if (k == 1) {
            x = b;
            y = a;
        }
        if (y.ty != NULL_TY) {
            continue;
        }
        if (this.t.is_ptr(x.ty)) {
            if (!eqne) {
                return fails(span, "only == and != work with null");
            }
            var r = vnew(BOOL, this.ir.binary(cmp_ir(op), x.c, this.ir.node(ir_kind::NULLPTR, x.ty), BOOL));
            r.pure = x.pure;
            return r;
        }
        val inner = this.t.opt_inner(x.ty);
        if (inner) {
            if (!eqne) {
                return fails(span, "only == and != work with null");
            }
            var is_null: u32 = 0;
            if (this.t.is_niche(inner)) {
                is_null = this.ir.binary(binop_ir::EQ, x.c, this.ir.node(ir_kind::NULLPTR, x.ty), BOOL);
            } else {
                is_null = this.ir.unary(unop_ir::NOT, this.opt_parts(x.ty, x.c).has, BOOL);
            }
            if (op == binop::NE) {
                is_null = this.ir.unary(unop_ir::NOT, is_null, BOOL);
            }
            var r = vnew(BOOL, is_null);
            r.pure = x.pure;
            return r;
        }
    }
    val u = try this.unify(a, b, span);
    var pair: std::vec<tval> = {};
    put(&pair, u.a);
    put(&pair, u.b);
    val pre = this.seq_vals(&pair);
    val av = *pair.at(0);
    val bv = *pair.at(1);
    val ordered = !eqne;
    var c: u32? = null;
    val plain = this.ir.binary(cmp_ir(op), av.c, bv.c, BOOL);
    match (*this.t.get(av.ty)) {
        .INT(x) => { c = plain; },
        .FLOAT(x) => { c = plain; },
        .BOOL => {
            if (!ordered) {
                c = plain;
            }
        },
        .REF(x) => {
            if (!ordered) {
                c = plain;
            }
        },
        .VOIDPTR => {
            if (!ordered) {
                c = plain;
            }
        },
        .FN_PTR(x, y, z) => {
            if (!ordered) {
                c = plain;
            }
        },
        .PTR(x) => { c = plain; },
        .OPT(inner) => {
            if (!ordered && this.t.is_niche(inner)) {
                c = plain;
            }
        },
        .STR => {
            if (!ordered) {
                var eq = try this.rt_any("volt_str_eq", nodes2(av.c, bv.c), BOOL);
                if (op == binop::NE) {
                    eq = this.ir.unary(unop_ir::NOT, eq, BOOL);
                }
                c = eq;
            }
        },
        .ANYERR => {
            if (!ordered) {
                c = plain;
            }
        },
        .ENUM(e) => {
            if (!ordered && !this.ei(e).has_payload) {
                c = plain;
            }
        },
        default => {},
    }
    val code = c ?? return fail(span, fmt2("can't compare {} with {}", this.ty_name(av.ty), S(sym)));
    var r = vnew(BOOL, this.wrap_pre(move pre, code, BOOL));
    r.pure = av.pure && bv.pure;
    return r;
}

// `l = r` and the compound forms (`l += r`...). A plain `=` goes through store (the value moves
// in, the old one is deleted); a compound one evaluates the target once.
attach fn assign(this: checker&, op: binop?, le: expr&, re: expr&, span: span) -> compile_error!tval {
    match (le.kind) {
        .PATH(p) => {
            if (p.is_single() && this.const_local(p.segs.at(0).name) != null) {
                return this.ct_assign(op, p.segs.at(0).name, re, span);
            }
        },
        .BUILTIN(n, g, a&) => {
            val ap = ptr_of(a);
            if (n == "field" && ap != null && ap->len == 2) {
                val fe = try this.field_form(ap->at(0), ap->at(1), le.span);
                return this.assign(op, &fe, re, span);
            }
        },
        default => {},
    }
    val l = try this.expr(le, null);
    if (!l.lv) {
        return fails(le.span, "can't assign to this; it's a temporary value");
    }
    if (!l.mutable) {
        if (l.rop) {
            return fails(le.span, "can't assign through this; it reaches a val (or a parameter without var)");
        }
        var e = fails(le.span, "can't assign to this; it's immutable (val, or a parameter without var)");
        if (l.own != null && l.root != null) {
            e = this.var_fix(move e, l.root ?? "", le.span);
        }
        return e;
    }
    this.note_write(&l);
    this.note_mut(&l);
    if (op == null) {
        // a narrowed optional takes either its payload type or the full optional back; a narrowed
        // pointer is always stored whole (its checked read would trap on a null one)
        val key = this.place_key(le);
        if (key) {
            val lo = this.lookup_local(key);
            if (lo != null && (lo ?? { c: 0, ty: 0, mutable: false }).orig_c != null) {
                val loc = lo ?? { c: 0, ty: 0, mutable: false };
                val r = try this.expr(re, l.ty);
                this.note_store(&l, &r);
                if (!this.coercible(&r, l.ty) || this.narrow_recheck(&loc)) {
                    var whole = vpure(loc.orig_ty, loc.orig_c ?? 0);
                    whole.lv = true;
                    whole.mutable = l.mutable;
                    return this.store(whole, r, re.span);
                }
                return this.store(l, r, re.span);
            }
        }
        // `x = f(move x)` may move x even inside a loop: it gets a new value right away
        var target: u32? = null;
        if (l.owner) {
            val ol = this.lookup_local(l.owner);
            if (ol) {
                target = (ol).c;
            }
        }
        val saved = this.cx.reassigning;
        this.cx.reassigning = target;
        val rr = this.expr(re, l.ty) catch |e| {
            this.cx.reassigning = saved;
            return copy e;
        };
        this.note_store(&l, &rr);
        val res = this.store(l, rr, re.span);
        this.cx.reassigning = saved;
        return res;
    }
    val bop = op ?? binop::ADD;
    val r = try this.expr(re, l.ty);
    val lty = l.ty;
    // evaluate the target once
    var pre: std::vec<u32> = {};
    var target = l.c;
    if (!l.pure) {
        val pt = this.t.ref_to(lty);
        val p = this.tmp_local("p", pt);
        put(&pre, this.ir.decl(p.id, this.ir.addr(l.c, pt)));
        target = this.ir.deref(p.c, lty);
    }
    var cur = l;
    cur.c = target;
    var v = vnew(0, 0);
    val is_ptr = this.t.get(lty);
    var ptr_target = false;
    match (*is_ptr) {
        .PTR(x) => { ptr_target = true; },
        default => {},
    }
    if (ptr_target) {
        // p += n, p -= n, p++, p--
        var rr = r;
        if (r.lit != null) {
            rr = try this.coerce(r, int_id(int_ty::ISIZE), re.span);
        }
        if ((bop != binop::ADD && bop != binop::SUB) || this.t.int_of(rr.ty) == null) {
            return fails(span, "pointers only move by an integer: p += n, p -= n, p++, p--");
        }
        var o = binop_ir::ADD;
        if (bop == binop::SUB) {
            o = binop_ir::SUB;
        }
        v = vnew(lty, this.ir.binary(o, target, rr.c, lty));
    } else if (bop == binop::SHL || bop == binop::SHR) {
        v = try this.shift(bop, cur, r, span);
    } else {
        val rc = try this.coerce(r, lty, re.span);
        match (*this.t.get(lty)) {
            .INT(k) => { v = vnew(lty, try this.int_arith(bop, k, target, rc.c, span, lty)); },
            .FLOAT(b) => {
                var o = binop_ir::ADD;
                match (bop) {
                    .ADD => { o = binop_ir::ADD; },
                    .SUB => { o = binop_ir::SUB; },
                    .MUL => { o = binop_ir::MUL; },
                    .DIV => { o = binop_ir::DIV; },
                    default => { return fail(span, fmt2("can't use {}= on {}", S(binop_text(bop)), this.ty_name(lty))); },
                }
                v = vnew(lty, this.ir.binary(o, target, rc.c, lty));
            },
            default => { return fail(span, fmt2("can't use {}= on {}", S(binop_text(bop)), this.ty_name(lty))); },
        }
    }
    val code = this.ir.assign(target, v.c);
    if (pre.len == 0) {
        return this.vstmt(code);
    }
    put(&pre, code);
    return this.vstmt(this.ir.seq(move pre, null, VOID));
}

// `place = value`: the value moves in; an old value that owns something is deleted first
attach fn store(this: checker&, l: tval, r: tval, span: span) -> compile_error!tval {
    val rv = try this.take_into(r, l.ty, span);
    if (!(try this.needs_drop(l.ty))) {
        return this.vstmt(this.ir.assign(l.c, rv.c));
    }
    val d = try this.drop_fn(l.ty);
    val pt = this.t.ref_to(l.ty);
    val n = this.tmp_local("n", l.ty);
    var stmts: std::vec<u32> = {};
    put(&stmts, this.ir.decl(n.id, rv.c));
    if (l.owner) {
        val local = this.lookup_local(l.owner) ?? return fails(span, "");
        val flag = local.flag ?? return fails(span, "");
        this.cx.moved.remove(local.c);
        put(&stmts, this.ir.if_(flag, this.call_fn(d, nodes(this.ir.addr(l.c, pt)), VOID), null));
        put(&stmts, this.ir.assign(l.c, n.c));
        put(&stmts, this.ir.assign(flag, this.ir.boolean(true)));
        return this.vstmt(this.ir.seq(move stmts, null, VOID));
    }
    val p = this.tmp_local("p", pt);
    put(&stmts, this.ir.decl(p.id, this.ir.addr(l.c, pt)));
    put(&stmts, this.call_fn(d, nodes(p.c), VOID));
    put(&stmts, this.ir.assign(this.ir.deref(p.c, l.ty), n.c));
    return this.vstmt(this.ir.seq(move stmts, null, VOID));
}

// `x as T`: lossless numeric conversions, int to float, bool or a plain enum to int, and the
// implicit conversions; anything that could lose data needs @cast
attach fn cast(this: checker&, x: expr&, to: u32, span: span) -> compile_error!tval {
    val v = try this.expr(x, to);
    if (v.ty == to) {
        return v;
    }
    if (v.lit != null && this.coercible(&v, to)) {
        return this.coerce(v, to, span);
    }
    var ok = false;
    val ft = this.t.get(v.ty);
    val tt = this.t.get(to);
    var decided = false;
    match (*ft) {
        .INT(a) => {
            match (*tt) {
                .INT(b) => {
                    ok = a.widens_to(b);
                    decided = true;
                },
                .FLOAT(b) => {
                    ok = true;
                    decided = true;
                },
                default => {},
            }
        },
        .BOOL => {
            match (*tt) {
                .INT(b) => {
                    ok = true;
                    decided = true;
                },
                default => {},
            }
        },
        .ENUM(e) => {
            match (*tt) {
                .INT(b) => {
                    ok = !this.ei(e).has_payload;
                    decided = true;
                },
                default => {},
            }
        },
        .FLOAT(a) => {
            match (*tt) {
                .FLOAT(b) => {
                    ok = a <= b;
                    decided = true;
                },
                default => {},
            }
        },
        default => {},
    }
    if (!decided) {
        ok = this.coercible(&v, to);
    }
    if (!ok) {
        return fail(span, fmt2("can't convert {} to {} with 'as' (it could lose data; @cast<T>(x) converts unchecked)", this.ty_name(v.ty), this.ty_name(to)));
    }
    if (this.t.int_of(to) != null || this.t.is_float(to)) {
        var r = vnew(to, this.ir.conv(v.c, to));
        r.pure = v.pure;
        return r;
    }
    return this.coerce(v, to, span);
}
