// match: an if-chain, each arm jumps to the end label. A binding copies its payload when the arm
// starts; a `x&` binding is a T& to the payload in place. Exhaustive = an unguarded catch-all, or
// every enum variant / bool value. A port of bootstrap/check/matching.rs.
use std::mem;

// what the unguarded arms so far cover, for check_exhaustive
struct coverage {
    all: bool = false;
    variants: idset = {};
    has_false: bool = false;
    has_true: bool = false;
}

// a local an arm declares, initialized from c (the payload's place, or its address for x&)
struct pat_bind {
    name: str;
    ty: u32;
    c: u32;
    by_ref: bool = false; // an x& binding, pointing into the matched place
}

// a pattern compiled against the scrutinee's place: its test, the locals it binds, and what an unguarded
// arm with it covers (irrefutable = matches every value)
struct pat_out {
    test: u32?;  // none: always matches
    binds: std::vec<pat_bind> = {};
    irrefutable: bool;
    variant: usize? = null;
    bool_val: bool? = null;
}

// `match (scrut) { arms }`: an if-chain over the scrutinee's slot. Its type is want, else the first arm
// with a value; NEVER when every arm leaves
attach fn match_expr(this: checker&, scrut: expr&, arms: std::vec<arm>&, want: u32?, span: span) -> compile_error!tval {
    val s = try this.expr(scrut, null);
    if (s.ty == VOID || s.ty == NEVER || s.ty == NULL_TY) {
        return fails(scrut.span, "can't match on this; it has no value");
    }
    // what x& bindings reach: the matched place, as &place would (lends.volt)
    var mp = vnew(0, 0);
    addr_prov(&mp, &s);
    var outp = vnew(0, 0); // the arms' values: read-only where any is
    val st = s.ty;
    // a place is matched where it is (x& bindings point into it; plain ones copy the payload when the
    // arm starts). A temporary gets a slot of its own, read again by the cleanup after the arms
    var m: u32 = 0;
    var place: u32 = 0;
    var stmts: std::vec<u32> = {};
    if (s.lv) {
        val rt = this.t.ref_to(st);
        m = this.slot("_mp", rt);
        place = this.ir.deref(m, st);
        put(&stmts, this.decl_at(m, this.ir.addr(s.c, rt)));
    } else {
        m = this.slot("_m", st);
        place = m;
        put(&stmts, this.decl_at(m, s.c));
    }
    val end = this.ir.label();
    var r: local_ref? = null;
    var result_ty: u32? = null;
    if ((want ?? VOID) != VOID) {
        result_ty = want;
    }
    var cov: coverage = {};
    var all_never = true;
    // a temporary scrutinee that owns something is deleted after the match, and by any return,
    // break or continue out of an arm (an exit of the scope around the arms)
    val tmp_drop = !s.lv && (try this.needs_drop(st));
    var around: scope = {};
    if (tmp_drop) {
        val flag = this.flag_for(m);
        put(&stmts, this.decl_at(flag, this.ir.boolean(true)));
        put(&around.exits, exit::DROP(m, try this.drop_fn(st), flag));
    }
    put(&this.cx.scopes, move around);
    // moves are tracked per arm, as per branch of an if: each arm starts from the moves before the
    // match (plus earlier guards': a guard runs even when its arm isn't taken), and the code after
    // sees the moves of the arms that reach it
    var base = copy this.cx.moved;
    var after = copy base;
    for (a&) in arms.items() {
        this.cx.moved = copy base;
        put(&this.cx.scopes, {});
        val res = this.match_arm(a, place, st, &result_ty, &r, &cov, &all_never, end, &base, &after, &mp, &outp);
        this.cx.scopes.pop();
        val arm_c = res catch |e| {
            this.cx.scopes.pop();
            return copy e;
        };
        put(&stmts, arm_c);
    }
    this.cx.scopes.pop();
    after.add_all(&base);
    this.cx.moved = move after;
    try this.check_exhaustive(st, &cov, span);
    // the arms cover every value, so falling off the chain means a corrupt value (say, a bad tag from C)
    if (this.opts.release) {
        put(&stmts, this.ir.node(ir_kind::UNREACHABLE, NEVER));
    } else {
        put(&stmts, this.ir.panic("no match arm matched", this.loc(span)));
    }
    put(&stmts, this.ir.label_at(end));
    if (tmp_drop) {
        val d = try this.drop_fn(st);
        put(&stmts, this.call_fn(d, nodes(this.ir.addr(m, this.t.ref_to(st))), VOID));
    }
    if (result_ty != null && !all_never) {
        val t = result_ty ?? 0;
        val rl = r ?? this.tmp_local("mr", t);
        var out = vnew(t, this.ir.seq(move stmts, rl.c, t));
        merge_prov(&out, &outp);
        return out;
    }
    var t = VOID;
    if (all_never && arms.len > 0) {
        t = NEVER;
    }
    return vnew(t, this.ir.seq(move stmts, null, t));
}

// one arm: `if (test) { binds; [if (guard)] { body; goto end; } }`. Updates the shared result type and
// slot, coverage and move sets
attach fn match_arm(this: checker&, a: arm&, m: u32, st: u32, result_ty: u32?&, r: local_ref?&, cov: coverage&, all_never: bool&, end: u32, base: idset&, after: idset&, mp: tval&, outp: tval&) -> compile_error!u32 {
    val p = try this.pat_code(&a.pat, m, st);
    var body_stmts: std::vec<u32> = {};
    this.lsp_at = a.pat.span;
    for (b&) in p.binds.items() {
        val local = this.new_local(b.name, b.ty, false);
        if (b.by_ref) {
            val x = this.scope_top().vars.get(b.name);
            if (x) {
                x.ro = mp.ro;
                x.via = mp.via;
                x.root = mp.root;
            }
        }
        put(&body_stmts, this.decl_at(local, b.c));
    }
    var guard: u32? = null;
    if (a.guard) {
        guard = (try this.expr_as(&a.guard, BOOL)).c;
    }
    *base = copy this.cx.moved;
    val body = try this.expr(&a.body, *result_ty);
    val reaches = body.ty != NEVER;
    var body_code: std::vec<u32> = {};
    if (body.ty == NEVER) {
        put(&body_code, body.c);
    } else {
        *all_never = false;
        if (body.ty == VOID) {
            if (*result_ty != null) {
                return fails(a.body.span, "this arm has no value, but the others do");
            }
            put(&body_code, body.c);
        } else {
            if (*result_ty == null) {
                *result_ty = body.ty;
            }
            val t = (*result_ty).value;
            val b = try this.coerce(body, t, a.body.span);
            merge_prov(outp, &b);
            if ((*r).none) {
                *r = this.tmp_local("mr", t);
            }
            put(&body_code, this.ir.assign((*r).value.c, b.c));
        }
        put(&body_code, this.ir.goto_(end));
    }
    if (reaches) {
        after.add_all(&this.cx.moved);
    }
    if (a.guard == null) {
        if (p.irrefutable) {
            cov.all = true;
        }
        if (p.variant) {
            cov.variants.add(@cast<u32>(p.variant));
        }
        // inside `if (p.bool_val)` the optional is narrowed, so the inner test reads the bool itself
        if (p.bool_val) {
            if (p.bool_val) {
                cov.has_true = true;
            } else {
                cov.has_false = true;
            }
        }
    }
    if (guard) {
        put(&body_stmts, this.ir.if_(guard, this.ir.block(move body_code), null));
    } else {
        for (x&) in body_code.items() {
            put(&body_stmts, *x);
        }
    }
    val inner = this.ir.block(move body_stmts);
    if (p.test) {
        return this.ir.if_(p.test, inner, null);
    }
    return inner;
}

// an error unless an unguarded arm matches anything, or the unguarded arms cover every variant of an
// enum, every member of a trait union, or both bools
attach fn check_exhaustive(this: checker&, t: u32, cov: coverage&, span: span) -> compile_error!void {
    if (cov.all) {
        return;
    }
    val eid = this.enum_of(t);
    if (eid) {
        var missing: std::string = {};
        val names = &this.ei(eid).names;
        for (i) in 0..names.len {
            if (!cov.variants.has(@cast<u32>(i))) {
                if (missing.len() > 0) {
                    missing.append(", ");
                }
                missing.append(*names.at(i));
            }
        }
        if (missing.len() == 0) {
            return;
        }
        return fail(span, fmt("match doesn't handle {} (add arms or a default)", move missing));
    }
    match (*this.t.get(t)) {
        .TRAIT_UNION(u) => {
            val members = copy this.ui(u).members;
            var missing: std::string = {};
            for (i) in 0..members.len {
                if (!cov.variants.has(@cast<u32>(i))) {
                    if (missing.len() > 0) {
                        missing.append(", ");
                    }
                    missing.append(this.ty_name(*members.at(i)).as_str());
                }
            }
            if (missing.len() == 0) {
                return;
            }
            return fail(span, fmt("match doesn't handle {} (add arms or a default)", move missing));
        },
        default => {},
    }
    if (t == BOOL && cov.has_false && cov.has_true) {
        return;
    }
    return fail(span, fmt("match on {} needs a default arm", this.ty_name(t)));
}

// a pattern that always matches and binds nothing
fn any_pat() -> pat_out {
    return { test: null, irrefutable: true };
}

// both tests hold (either may be "always")
attach fn and_test(this: checker&, a: u32?, b: u32?) -> u32? {
    if (a == null) {
        return b;
    }
    if (b == null) {
        return a;
    }
    return this.ir.binary(binop_ir::AND, a ?? 0, b ?? 0, BOOL);
}

// compiles pattern p against the place c of type t
attach fn pat_code(this: checker&, p: pat&, c: u32, t: u32) -> compile_error!pat_out {
    val span = p.span;
    match (p.kind) {
        .WILD => { return any_pat(); },
        .BIND_REF(n) => {
            val rt = this.t.ref_to(t);
            var o = any_pat();
            put(&o.binds, { name: n, ty: rt, c: this.ir.addr(c, rt), by_ref: true });
            return move o;
        },
        .BIND(n) => {
            val eid = this.enum_of(t);
            // a bare name that is one of the enum's variants matches that variant instead of binding
            if (eid != null && this.variant_index(eid ?? 0, n) != null) {
                val q: pat = { kind: pat_kind::CTOR(ctor_path::DOT(n), null), span: span };
                return this.pat_code(&q, c, t);
            }
            var o = any_pat();
            put(&o.binds, { name: n, ty: t, c: c });
            return move o;
        },
        .LIT(e&) => {
            val v = try this.expr(e, t);
            var bool_val: bool? = null;
            if (t == BOOL) {
                match (e.kind) {
                    .BOOL(b) => { bool_val = b; },
                    default => {},
                }
            }
            val test = try this.compare(binop::EQ, vpure(t, c), v, span);
            return { test: test.c, irrefutable: false, bool_val: bool_val };
        },
        .RANGE(lo&, hi&, incl) => {
            if (this.t.int_of(t) == null) {
                return fail(span, fmt("range patterns need an integer, found {}", this.ty_name(t)));
            }
            val l = try this.expr_as(lo, t);
            val h = try this.expr_as(hi, t);
            var op = binop_ir::LT;
            if (incl) {
                op = binop_ir::LE;
            }
            val test = this.ir.binary(binop_ir::AND, this.ir.binary(binop_ir::GE, c, l.c, BOOL), this.ir.binary(op, c, h.c, BOOL), BOOL);
            return { test: test, irrefutable: false };
        },
        .TUPLE(pats&) => {
            var ts: std::vec<u32> = {};
            match (*this.t.get(t)) {
                .TUPLE(xs, names) => { ts = copy xs; },
                default => { return fail(span, fmt("tuple pattern, but the value is a {}", this.ty_name(t))); },
            }
            if (ts.len != pats.len) {
                return fail(span, fmt2("expected {} elements, found {}", unum(@cast<u64>(ts.len)), unum(@cast<u64>(pats.len))));
            }
            return this.sub_pats(pats, &ts, c);
        },
        .CTOR(path&, args&) => {
            match (*this.t.get(t)) {
                .TRAIT_UNION(u) => {
                    match (*path) {
                        .PATH(pp&) => { return this.union_pat(pp, ptr_of(args), c, t, span); },
                        default => {},
                    }
                },
                default => {},
            }
            return this.ctor_pat(path, ptr_of(args), c, t, span);
        },
    }
}

// member-type pattern on a trait union: circle(c)
attach fn union_pat(this: checker&, pp: path&, args: std::vec<pat>*, c: u32, t: u32, span: span) -> compile_error!pat_out {
    val mty = try this.resolve_type_path(pp, this.cx.env);
    val i = this.union_member(t, mty) ?? return fail(span, fmt2("{} isn't one of the types in {}", this.ty_name(mty), this.ty_name(t)));
    val tag = this.ir.field(c, 0, int_id(int_ty::U16));
    val test = this.ir.binary(binop_ir::EQ, tag, this.ir.int(@cast<i128>(i), int_id(int_ty::U16)), BOOL);
    val mc = this.ir.field(c, @cast<u32>(i) + 1, mty);
    if (args == null || (args ?? return fails(span, "")).len == 0) {
        return { test: test, irrefutable: false, variant: i };
    }
    val a = args ?? return fails(span, "");
    if (a.len != 1) {
        return fails(span, "a type pattern takes one name: circle(c)");
    }
    var o = try this.pat_code(a.at(0), mc, mty);
    val full = o.irrefutable;
    o.test = this.and_test(test, o.test);
    o.irrefutable = false;
    o.variant = null;
    if (full) {
        o.variant = i;
    }
    o.bool_val = null;
    return move o;
}

// a variant pattern: `.X(sub)`, `X(sub)` or `Enum::X(sub)`, with an optional payload pattern
attach fn ctor_pat(this: checker&, path: ctor_path&, args: std::vec<pat>*, c: u32, t: u32, span: span) -> compile_error!pat_out {
    // which enum + variant
    var ety = t;
    var name: str = "";
    match (*path) {
        .DOT(n) => { name = n; },
        .PATH(p&) => {
            if (p.segs.len == 1) {
                name = p.segs.at(0).name;
            } else {
                val found = try this.member_path(p);
                val m = found ?? return fail(span, fmt("unknown variant '{}'", S(p.last())));
                match (m) {
                    .OF(x, n) => {
                        ety = x;
                        name = n;
                    },
                    .GENERIC_ENUM(d, n) => {
                        ety = try this.infer_enum(d, n, null, t, span);
                        name = n;
                    },
                }
            }
        },
    }
    val eid = this.enum_of(ety) ?? return fail(span, fmt("{} has no variants to match", this.ty_name(t)));
    if (ety != t && !(t == ANYERR && this.ei(eid).is_error)) {
        return fail(span, fmt2("this is a {} variant, but the value is a {}", this.ty_name(ety), this.ty_name(t)));
    }
    val idx = this.variant_index(eid, name) ?? return fail(span, fmt2("{} has no variant {}", this.ty_name(ety), S(name)));
    val value = *this.ei(eid).values.at(idx);
    val tagt = int_id(this.ei(eid).tag);
    var tag_expr = c;
    // an `error` value is its code already, so any error set's variant can be tested against it
    // (but never counts toward coverage)
    if (t != ANYERR) {
        tag_expr = this.tag_of(eid, c);
    }
    val test = this.ir.binary(binop_ir::EQ, tag_expr, this.ir.int(value, this.ir.ty_of(tag_expr)), BOOL);
    val payload = *(try this.enum_payloads(eid, span)).at(idx);
    var variant: usize? = null;
    if (ety == t) {
        variant = idx;
    }
    val pats = args ?? return { test: test, irrefutable: false, variant: variant };
    if (payload == null) {
        if (pats.len == 0) {
            return { test: test, irrefutable: false, variant: variant };
        }
        return fail(span, fmt("{} has no payload", S(name)));
    }
    val pt = payload ?? 0;
    val pc = this.ir.field(c, @cast<u32>(idx) + 1, pt);
    var out: pat_out = any_pat();
    var done = false;
    match (*this.t.get(pt)) {
        .TUPLE(ts, names) => {
            if (pats.len == ts.len && pats.len != 1) {
                val xs = copy ts;
                out = try this.sub_pats(pats, &xs, pc);
                done = true;
            }
        },
        default => {},
    }
    if (!done) {
        if (pats.len != 1) {
            return fail(span, fmt("{} has one payload value", S(name)));
        }
        out = try this.pat_code(pats.at(0), pc, pt);
    }
    val sub_irrefutable = out.irrefutable;
    out.test = this.and_test(test, out.test);
    out.irrefutable = false;
    out.variant = null;
    if (sub_irrefutable) {
        out.variant = variant;
    }
    out.bool_val = null;
    return move out;
}

// element patterns that must all match; element i is field i of c
attach fn sub_pats(this: checker&, pats: std::vec<pat>&, tys: std::vec<u32>&, c: u32) -> compile_error!pat_out {
    var out = any_pat();
    for (i) in 0..pats.len {
        val et = *tys.at(i);
        val o = try this.pat_code(pats.at(i), this.ir.field(c, @cast<u32>(i), et), et);
        out.test = this.and_test(out.test, o.test);
        for (b&) in o.binds.items() {
            put(&out.binds, *b);
        }
        out.irrefutable = out.irrefutable && o.irrefutable;
    }
    return move out;
}
