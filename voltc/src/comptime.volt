// Compile-time evaluation: a small tree-walking interpreter over the AST. A port of
// bootstrap/check/comptime.rs. Values carry their type (ints with VOID as "untyped literal"), so results
// can become runtime constants afterwards. return/break/continue travel as a "<flow>" error with
// the flow itself in checker.ct_flow, so `try` works on the way out.
use std::mem;

// a compile-time value. INT and FLOAT carry their type (VOID while an untyped literal); OPT carries the
// optional type (T?, not T)
enum cval {
    VOID,
    NULL,
    BOOL: bool,
    INT: (i128, u32),   // VOID = an untyped literal
    FLOAT: (f64, u32),
    STR: std::string,
    TYPE: u32,
    TUPLE: std::vec<cval>,
    ARRAY: (std::vec<cval>, u32),             // element type
    STRUCT: (u32, std::vec<cfield>),          // VOID = a comptime-only record (typeinfo)
    VARIANT: (u32, str, std::box<cval>?),     // enum value (VOID for typeinfo kinds)
    OPT: (u32, std::box<cval>?),
}

struct cfield {
    name: str;
    v: cval;
}

// a return, break or continue on its way out to the call or loop that handles it (see ct_leave)
enum flow {
    RET: cval,
    BRK: (str?, cval?),
    CONT: str?,
}

// one interpreted call: its scopes of name -> (value, mutable), and the env its names resolve in
struct ct_frame {
    scopes: std::vec<std::map<str, const_entry>>;
    env: u32;
}

// a type's size and alignment in bytes
struct lay {
    size: u64;
    align: u64;
}

// limits that turn an endless loop or recursion into an error
val MAX_STEPS: u64 = 20000000;
val MAX_DEPTH: usize = 256;

// ---------- flow ----------

// starts a return/break/continue: parks the flow in ct_flow and fails with the "<flow>" marker error
attach fn ct_leave(this: checker&, f: flow, span: span) -> compile_error {
    this.ct_flow = move f;
    return fails(span, "<flow>");
}

// the pending flow, if an error is one (taken, so it's handled once)
attach fn take_flow(this: checker&) -> flow? {
    var f: flow? = null;
    swap(&f, &this.ct_flow);
    return f;
}

// run r: null when it finished, its flow when it left by return/break/continue
attach fn flow_of(this: checker&, r: compile_error!void) -> compile_error!(flow?) {
    r catch |e| {
        val f = this.take_flow();
        if (f == null) {
            return copy e;
        }
        return f;
    };
    return null;
}

// does a break/continue labeled `l` (none: the innermost) leave this loop?
fn is_mine(l: str?, label: str?) -> bool {
    if (l == null) {
        return true;
    }
    return label != null && (l ?? "") == (label ?? "");
}

// a present optional payload
fn some_c(v: cval) -> std::box<cval>? {
    return bx(move v);
}

// ---------- entry points ----------

attach fn ct_eval(this: checker&, e: expr&, want: u32?) -> compile_error!cval {
    return this.ct_eval_in(this.cx.env, e, want);
}

// evaluates with names resolved in env, in a fresh frame; control flow can't leave it
attach fn ct_eval_in(this: checker&, env: u32, e: expr&, want: u32?) -> compile_error!cval {
    var fr: ct_frame = { scopes: {}, env: env };
    put(&fr.scopes, {});
    put(&this.ct, move fr);
    val r = this.ct_expr(e, want);
    this.ct.pop();
    val v = r catch |x| {
        if (this.take_flow() != null) {
            return fails(e.span, "return/break/continue can't leave a compile-time expression");
        }
        return copy x;
    };
    return v;
}

// is this expression only meaningful at compile time (so it gets evaluated, not emitted)?
attach fn is_ct_expr(this: checker&, e: expr&) -> bool {
    match (e.kind) {
        .QUOTE(p) => { return true; },
        .BUILTIN(n, g, a) => { return n == "typeinfo" || n == "typeof" || n == "compile_error" || n == "cfg" || n == "attaches" || n == "has_method" || n == "has_field"; },
        .CALL(c, args) => {
            match (c.kind) {
                .PATH(p&) => {
                    val ns = this.env_at(this.cx.env).ns;
                    var f: found? = null;
                    if (p.segs.len == 1) {
                        f = this.lookup(ns, p.segs.at(0).name);
                    } else {
                        f = this.lookup_path_ns(ns, p);
                    }
                    if (p.is_single() && this.lookup_local(p.segs.at(0).name) != null) {
                        return false;
                    }
                    match (f ?? found::NS(0)) {
                        .DECLS(l) => {
                            val ds = this.list(l);
                            if (ds.len == 0) {
                                return false;
                            }
                            for (d&) in ds.items() {
                                val fd = this.fn_decl_of(*d) ?? return false;
                                if (!fd.is_comptime) {
                                    return false;
                                }
                            }
                            return true;
                        },
                        default => { return false; },
                    }
                },
                default => { return false; },
            }
        },
        .FIELD(b, n, g) => { return g == null && this.is_ct_expr(b); },
        .INDEX(b, i) => { return this.is_ct_expr(b); },
        .PATH(p) => { return p.is_single() && this.const_local(p.segs.at(0).name) != null; },
        default => { return false; },
    }
}

// a comptime local visible from the running function
attach fn const_local(this: checker&, name: str) -> cval? {
    var i = this.cx.scopes.len;
    while (i > 0) {
        i -= 1;
        val s = this.cx.scopes.at(i);
        if (s.vars.get(name) != null) {
            return null; // a runtime local shadows it
        }
        val c = s.consts.get(name);
        if (c) {
            return copy c.value;
        }
        if (s.barrier) {
            break;
        }
    }
    return null;
}

// a comptime local of the running fn, or else of the innermost compile-time frame
attach fn const_or_ct_local(this: checker&, name: str) -> cval? {
    val c = this.const_local(name);
    if (c != null || this.ct.len == 0) {
        return c;
    }
    val f = this.ct_top();
    var i = f.scopes.len;
    while (i > 0) {
        i -= 1;
        val e = f.scopes.at(i).get(name);
        if (e) {
            return copy e.value;
        }
    }
    return null;
}

// assigns a comptime var of the running fn (a comptime val can't change)
attach fn set_const_local(this: checker&, name: str, v: cval, span: span) -> compile_error!void {
    var i = this.cx.scopes.len;
    while (i > 0) {
        i -= 1;
        val c = this.cx.scopes.at(i).consts.get(name);
        if (c) {
            if (!c.mutable) {
                return fail(span, fmt("'{}' is a comptime val; it can't change", S(name)));
            }
            c.value = copy v;
            return;
        }
    }
    return fail(span, fmt("no comptime variable '{}'", S(name)));
}

// comptime var/val inside a runtime function
attach fn ct_let(this: checker&, l: let_stmt&) -> compile_error!void {
    var name: str = "";
    match (l.pat.kind) {
        .BIND(n) => { name = n; },
        default => { return fails(l.pat.span, "comptime variables take a single name"); },
    }
    var t: u32? = null;
    if (l.ty) {
        t = try this.resolve_type(&l.ty, this.cx.env);
    }
    var v = cval::VOID;
    if (l.init) {
        v = try this.ct_eval(&l.init, t);
        if (t) {
            v = try this.ct_coerce(move v, t, l.init.span);
        }
    }
    this.scope_top().consts.put(name, { value: move v, mutable: l.mutable });
}

// `x = v` / `x += v` where x is a comptime local
attach fn ct_assign(this: checker&, op: binop?, name: str, rhs: expr&, span: span) -> compile_error!tval {
    val cur = this.const_local(name) ?? return fails(span, "");
    var v = try this.ct_eval(rhs, null);
    if (op) {
        v = try this.ct_binop(op, move cur, move v, span);
    }
    try this.set_const_local(name, move v, span);
    return this.vstmt(this.nop());
}

// ---------- materializing ----------

// a compile-time value as IR for the runtime code; types and typeinfo records can't cross over
attach fn ct_to_val(this: checker&, v: cval, want: u32?, span: span) -> compile_error!tval {
    match (v) {
        .VOID => { return this.vstmt(this.nop()); },
        .NULL => {
            if (want != null && this.t.opt_inner(want ?? 0) != null) {
                return this.none(want ?? 0);
            }
            return vpure(NULL_TY, this.ir.node(ir_kind::NULLPTR, NULL_TY));
        },
        .BOOL(b) => { return vpure(BOOL, this.ir.boolean(b)); },
        .INT(x, t) => {
            if (t == VOID) {
                return this.int_lit(x, want);
            }
            return this.int_lit(x, t);
        },
        .FLOAT(x, t) => {
            var ft = t;
            if (ft == VOID) {
                ft = F64;
                if (want != null && this.t.is_float(want ?? 0)) {
                    ft = want ?? F64;
                }
            }
            return this.float_lit(x, ft);
        },
        .STR(s) => {
            val sv = this.str_val(this.intern(copy s));
            if (want != null && (want ?? 0) == CSTR) {
                return this.coerce(sv, CSTR, span);
            }
            return sv;
        },
        .TYPE(t) => { return fail(span, fmt("the type {} is only a value at compile time", this.ty_name(t))); },
        .TUPLE(es) => {
            var tys: std::vec<u32> = {};
            var names: std::vec<str?> = {};
            var inits: std::vec<field_init> = {};
            for (i) in 0..es.len {
                val ev = try this.ct_to_val(copy *es.at(i), null, span);
                put(&tys, ev.ty);
                put(&names, null);
                put(&inits, { field: @cast<u32>(i), value: ev.c });
            }
            val ty = this.t.intern(tyk::TUPLE(move tys, move names));
            return vpure(ty, this.ir.node(ir_kind::AGG(move inits), ty));
        },
        .ARRAY(es, et0) => {
            // an untyped list: its first element's type when that has one (an untyped literal's doesn't), else i32
            var et = et0;
            if (et == VOID) {
                et = I32;
                if (es.len > 0 && this.ct_type_of(es.at(0)) != VOID) {
                    et = this.ct_type_of(es.at(0));
                }
            }
            val ty = this.t.intern(tyk::ARRAY(et, @cast<u64>(es.len)));
            var cs: std::vec<u32> = {};
            for (e&) in es.items() {
                val ev = try this.ct_to_val(copy *e, et, span);
                put(&cs, (try this.coerce(ev, et, span)).c);
            }
            return vpure(ty, this.ir.node(ir_kind::ARRAY_LIT(move cs), ty));
        },
        .STRUCT(t, fields) => {
            if (t == VOID) {
                return fails(span, "this compile-time record (like typeinfo) can't exist at runtime; read one of its fields");
            }
            var sid: u32 = 0;
            match (*this.t.get(t)) {
                .STRUCT(s) => { sid = s; },
                default => { return fails(span, "bad struct value"); },
            }
            var inits: std::vec<field_init> = {};
            for (f&) in fields.items() {
                var fi: usize? = null;
                var fty: u32? = null;
                val infos = try this.struct_fields(sid, span);
                for (k) in 0..infos.len {
                    if (infos.at(k).name == f.name) {
                        fi = k;
                        fty = infos.at(k).ty;
                    }
                }
                var fv = try this.ct_to_val(copy f.v, fty, span);
                if (fty) {
                    fv = try this.coerce(fv, fty, span);
                }
                if (fi) {
                    put(&inits, { field: @cast<u32>(fi), value: fv.c });
                }
            }
            return vpure(t, this.ir.node(ir_kind::AGG(move inits), t));
        },
        .VARIANT(t, n, payload) => {
            if (t == VOID) {
                return fail(span, fmt("{} is a compile-time-only value", S(n)));
            }
            val eid = this.enum_of(t) ?? return fails(span, "not an enum");
            val idx = this.variant_index(eid, n) ?? return fails(span, "no such variant");
            if (payload == null) {
                return this.make_variant(t, idx, null, span);
            }
            val pt = *(try this.enum_payloads(eid, span)).at(idx) ?? return fail(span, fmt("{} has no payload", S(n)));
            val pv = try this.ct_to_val(copy *payload.value.ptr, null, span);
            val pc = try this.coerce(pv, pt, span);
            var inits: std::vec<field_init> = {};
            put(&inits, { field: 0, value: this.tag_const(eid, idx) });
            put(&inits, { field: @cast<u32>(idx) + 1, value: pc.c });
            return vnew(t, this.ir.node(ir_kind::AGG(move inits), t));
        },
        .OPT(t, inner) => {
            if (inner == null) {
                return this.none(t);
            }
            val it = this.t.opt_inner(t) ?? return fails(span, "not an optional");
            val iv = try this.ct_to_val(copy *inner.value.ptr, it, span);
            val ic = try this.coerce(iv, it, span);
            return this.some(ic, t);
        },
    }
}

// the type of a compile-time value; an untyped int is i32 and an untyped float f64
attach fn ct_type_of(this: checker&, v: cval&) -> u32 {
    match (*v) {
        .VOID => { return VOID; },
        .NULL => { return NULL_TY; },
        .BOOL(b) => { return BOOL; },
        .INT(x, t) => {
            if (t == VOID) {
                return I32;
            }
            return t;
        },
        .FLOAT(x, t) => {
            if (t == VOID) {
                return F64;
            }
            return t;
        },
        .STR(s) => { return STR; },
        .TYPE(t) => { return TYPE; },
        .TUPLE(es) => {
            var ts: std::vec<u32> = {};
            var names: std::vec<str?> = {};
            for (e&) in es.items() {
                put(&ts, this.ct_type_of(e));
                put(&names, null);
            }
            return this.t.intern(tyk::TUPLE(move ts, move names));
        },
        .ARRAY(es, et) => {
            var t = et;
            if (t == VOID) {
                t = I32;
                if (es.len > 0) {
                    t = this.ct_type_of(es.at(0));
                }
            }
            return this.t.intern(tyk::ARRAY(t, @cast<u64>(es.len)));
        },
        .STRUCT(t, f) => { return t; },
        .VARIANT(t, n, p) => { return t; },
        .OPT(t, x) => { return t; },
    }
}

// converts v to t by the implicit rules: ints must fit, a value wraps into an optional, arrays and
// tuples convert element by element
attach fn ct_coerce(this: checker&, v: cval, t: u32, span: span) -> compile_error!cval {
    val have = this.ct_type_of(&v);
    if (have == t) {
        return v;
    }
    match (v) {
        .TYPE(x) => {
            if (t == TYPE) {
                return copy v;
            }
        },
        default => {},
    }
    val tt = copy *this.t.get(t);
    match (v) {
        .INT(x, from) => {
            match (tt) {
                .INT(k) => {
                    if (!k.fits(x)) {
                        return fail(span, fmt2("{} doesn't fit in {}", num(x), S(k.name())));
                    }
                    return cval::INT(x, t);
                },
                .FLOAT(b) => { return cval::FLOAT(@cast<f64>(x), t); },
                default => {},
            }
        },
        .FLOAT(x, from) => {
            match (tt) {
                .FLOAT(b) => { return cval::FLOAT(x, t); },
                default => {},
            }
        },
        .STR(s) => {
            if (t == CSTR) {
                return copy v;
            }
        },
        .NULL => {
            match (tt) {
                .OPT(i) => { return cval::OPT(t, null); },
                default => {},
            }
        },
        .OPT(o, inner) => {
            match (tt) {
                .OPT(i) => {
                    var r: std::box<cval>? = null;
                    if (inner) {
                        r = bx(copy *inner.ptr);
                    }
                    return cval::OPT(t, move r);
                },
                default => {},
            }
        },
        default => {},
    }
    match (tt) {
        .OPT(inner) => {
            val c = try this.ct_coerce(copy v, inner, span);
            return cval::OPT(t, some_c(move c));
        },
        .ARRAY(et, n) => {
            match (v) {
                .ARRAY(es, x) => {
                    if (@cast<u64>(es.len) == n) {
                        var out: std::vec<cval> = {};
                        for (e&) in es.items() {
                            put(&out, try this.ct_coerce(copy *e, et, span));
                        }
                        return cval::ARRAY(move out, et);
                    }
                },
                default => {},
            }
        },
        .TUPLE(ts, names) => {
            match (v) {
                .TUPLE(es) => {
                    if (es.len == ts.len) {
                        var out: std::vec<cval> = {};
                        for (i) in 0..es.len {
                            put(&out, try this.ct_coerce(copy *es.at(i), *ts.at(i), span));
                        }
                        return cval::TUPLE(move out);
                    }
                },
                default => {},
            }
        },
        default => {},
    }
    return type_diff(fail(span, fmt2("expected {}, found {}", this.ty_name(t), this.ty_name(have))));
}

// ---------- the interpreter ----------

// the running interpreted call
attach fn ct_top(this: checker&) -> ct_frame& {
    return this.ct.at(this.ct.len - 1);
}

// its innermost scope
attach fn ct_scope(this: checker&) -> std::map<str, const_entry>& {
    val f = this.ct_top();
    return f.scopes.at(f.scopes.len - 1);
}

// a variable of the running interpreted call; the outermost frame also sees the fn's comptime locals
attach fn ct_lookup(this: checker&, name: str) -> cval? {
    val f = this.ct_top();
    var i = f.scopes.len;
    while (i > 0) {
        i -= 1;
        val c = f.scopes.at(i).get(name);
        if (c) {
            return copy c.value;
        }
    }
    if (this.ct.len == 1) {
        return this.const_local(name);
    }
    return null;
}

// assigns an existing variable; a val can't change
attach fn ct_set(this: checker&, name: str, v: cval, span: span) -> compile_error!void {
    val f = this.ct_top();
    var i = f.scopes.len;
    while (i > 0) {
        i -= 1;
        val c = f.scopes.at(i).get(name);
        if (c) {
            if (!c.mutable) {
                return fail(span, fmt("'{}' is a val; it can't change", S(name)));
            }
            c.value = copy v;
            return;
        }
    }
    if (this.ct.len == 1 && this.const_local(name) != null) {
        return this.set_const_local(name, move v, span);
    }
    return fail(span, fmt("'{}' isn't a compile-time variable", S(name)));
}

// counts one evaluation step; past MAX_STEPS it's an error
attach fn ct_step(this: checker&, span: span) -> compile_error!void {
    this.ct_steps += 1;
    if (this.ct_steps > MAX_STEPS) {
        return fails(span, "compile-time evaluation took too long (over 20M steps); is there an endless loop?");
    }
}

// a generic argument as a compile-time value (a pack is a tuple of types)
attach fn gval_cval(this: checker&, g: gval&) -> cval {
    match (*g) {
        .TY(t) => { return cval::TYPE(t); },
        .INT(v) => { return cval::INT(v, VOID); },
        .STR(s) => { return cval::STR(S(s)); },
        .PACK(l) => {
            var es: std::vec<cval> = {};
            for (t&) in this.list(l).items() {
                put(&es, cval::TYPE(*t));
            }
            return cval::TUPLE(move es);
        },
    }
}

// a name at compile time: an interpreted variable, a generic param, a primitive type, a global val's
// value (its initializer, evaluated again on each use), a type, or Enum::VARIANT
attach fn ct_path(this: checker&, p: path&, want: u32?, span: span) -> compile_error!cval {
    if (p.is_single()) {
        val name = p.segs.at(0).name;
        val v = this.ct_lookup(name);
        if (v) {
            match (v) {
                .VOID => { return fail(span, fmt("'{}' has no value yet", S(name))); },
                default => { return copy v; },
            }
        }
        val e = this.ct_top().env;
        val gs = &this.env_at(e).generics;
        var i = gs.len;
        while (i > 0) {
            i -= 1;
            if (gs.at(i).name == name) {
                return this.gval_cval(&gs.at(i).g);
            }
        }
        if (this.ct.len == 1 && this.lookup_local(name) != null) {
            return fail(span, fmt("'{}' is a runtime variable, so its value isn't known at compile time", S(name)));
        }
        val prim = primitive(name);
        if (prim) {
            return cval::TYPE(prim);
        }
    }
    val env = this.ct_top().env;
    val ns = this.env_at(env).ns;
    var f: found? = null;
    if (p.segs.len == 1) {
        f = this.lookup(ns, p.segs.at(0).name);
    } else {
        f = this.lookup_path_ns(ns, p);
    }
    match (f ?? found::NS(0)) {
        .DECLS(l) => {
            if (f != null) {
                val d = *this.list(l).at(0);
                try this.visible(d, span);
                match (this.item_of(d).kind) {
                    .GLOBAL(g&) => {
                        if (g.mutable && !g.is_comptime) {
                            return fail(span, fmt("'{}' is a runtime var; its value isn't known at compile time", S(p.last())));
                        }
                        if (g.init == null) {
                            return fails(span, "this global has no value");
                        }
                        val genv = this.new_env({ ns: this.dl(d).ns });
                        // the declared type guides the value (a struct literal is that struct)
                        if (g.ty) {
                            val t = try this.resolve_type(&g.ty, genv);
                            val tv = try this.ct_eval_in(genv, &g.init.value, t);
                            return this.ct_coerce(move tv, t, span);
                        }
                        return this.ct_eval_in(genv, &g.init.value, null);
                    },
                    .STRUCT(s) => { return cval::TYPE(try this.resolve_type_path(p, env)); },
                    .ENUM(x) => { return cval::TYPE(try this.resolve_type_path(p, env)); },
                    .TRAIT(n, items) => { return cval::TYPE(try this.resolve_type_path(p, env)); },
                    default => { return fail(span, fmt("'{}' isn't a compile-time value", S(p.last()))); },
                }
            }
        },
        default => {},
    }
    // Enum::VARIANT or a type path
    val m = try this.member_path(p);
    if (m) {
        match (m) {
            .OF(t, name) => {
                val eid = this.enum_of(t);
                if (eid != null && this.variant_index(eid ?? 0, name) != null) {
                    return cval::VARIANT(t, name, null);
                }
            },
            default => {},
        }
    }
    val t = this.resolve_type_path(p, env) catch |x| {
        return fail(span, fmt("unknown name '{}'", S(p.last())));
    };
    return cval::TYPE(t);
}

// evaluates e; want types untyped literals and resolves `.VARIANT`. Blocks and ifs give no value (only a
// break out of a labeled block or a `loop` carries one)
attach fn ct_expr(this: checker&, e: expr&, want: u32?) -> compile_error!cval {
    try this.ct_step(e.span);
    val span = e.span;
    match (e.kind) {
        .INT(v) => {
            var t = VOID;
            if (want != null && this.t.int_of(want ?? 0) != null) {
                t = want ?? VOID;
            }
            return cval::INT(@cast<i128>(v), t);
        },
        .CHAR(v) => { return cval::INT(@cast<i128>(v), VOID); },
        .FLOAT(v) => {
            var t = VOID;
            if (want != null && this.t.is_float(want ?? 0)) {
                t = want ?? VOID;
            }
            return cval::FLOAT(v, t);
        },
        .STR(s) => { return cval::STR(copy s); },
        .QUOTE(parts&) => {
            var out: std::string = {};
            for (p&) in parts.items() {
                out.append(p.text);
                if (p.splice) {
                    val x = &p.splice;
                    val v = try this.ct_expr(x, null);
                    out.append((try this.splice_text(v, x.span)).as_str());
                }
            }
            return cval::STR(move out);
        },
        .BOOL(b) => { return cval::BOOL(b); },
        .NULL => { return cval::NULL; },
        .PATH(p&) => { return this.ct_path(p, want, span); },
        .DOT_VARIANT(n) => {
            val t = this.dot_target(want) ?? return fail(span, fmt("can't tell which enum .{} belongs to", S(n)));
            return cval::VARIANT(t, n, null);
        },
        .UNARY(op, x) => {
            val v = try this.ct_expr(x, want);
            match (v) {
                .INT(n, t) => {
                    if (op == unop::NEG) {
                        return cval::INT(-n, t);
                    }
                    if (op == unop::BITNOT) {
                        return cval::INT(~n, t);
                    }
                },
                .FLOAT(f, t) => {
                    if (op == unop::NEG) {
                        return cval::FLOAT(-f, t);
                    }
                },
                .BOOL(b) => {
                    if (op == unop::NOT) {
                        return cval::BOOL(!b);
                    }
                },
                default => {},
            }
            return fails(span, "this operator doesn't work on that value at compile time");
        },
        .BINARY(op, a, b) => {
            if (op == binop::AND || op == binop::OR) {
                val av = try this.ct_bool(a);
                if ((op == binop::AND) != av) {
                    return cval::BOOL(av);
                }
                return cval::BOOL(try this.ct_bool(b));
            }
            val av = try this.ct_expr(a, null);
            var at: u32? = null;
            match (av) {
                .INT(x, t) => {
                    if (t != VOID) {
                        at = t;
                    }
                },
                default => { at = this.ct_type_of(&av); },
            }
            val bv = try this.ct_expr(b, at);
            return this.ct_binop(op, move av, move bv, span);
        },
        .ASSIGN(op, l, r) => {
            val rv = try this.ct_expr(r, null);
            try this.ct_store(l, op, move rv, span);
            return cval::VOID;
        },
        .INC_DEC(x, inc) => {
            var op = binop::SUB;
            if (inc) {
                op = binop::ADD;
            }
            try this.ct_store(x, op, cval::INT(1, VOID), span);
            return cval::VOID;
        },
        .CAST(x, t&) => {
            val to = try this.resolve_type(t, this.ct_top().env);
            val v = try this.ct_expr(x, to);
            return this.ct_convert(move v, to, false, span);
        },
        .TUPLE(es) => {
            var out: std::vec<cval> = {};
            for (x&) in es.items() {
                put(&out, try this.ct_expr(x, null));
            }
            return cval::TUPLE(move out);
        },
        .LITERAL(entries&) => { return this.ct_literal(entries, want, span); },
        .REPEAT(x, n) => { return this.ct_repeat(x, n, want, span); },
        .FIELD(b, name, g) => {
            val bv = try this.ct_expr(b, null);
            return this.ct_field(move bv, name, span);
        },
        .INDEX(b, i) => {
            val bv = try this.ct_expr(b, null);
            val iv = try this.ct_expr(i, USIZE);
            var k: i128 = 0;
            match (iv) {
                .INT(x, t) => { k = x; },
                default => { return fails(span, "index must be an integer"); },
            }
            match (bv) {
                .ARRAY(es, t) => {
                    if (k < 0 || k >= @cast<i128>(es.len)) {
                        return fail(span, fmt2("index {} out of bounds (len {})", num(k), unum(@cast<u64>(es.len))));
                    }
                    return copy *es.at(@cast<usize>(k));
                },
                .TUPLE(es) => {
                    if (k < 0 || k >= @cast<i128>(es.len)) {
                        return fail(span, fmt2("index {} out of bounds (len {})", num(k), unum(@cast<u64>(es.len))));
                    }
                    return copy *es.at(@cast<usize>(k));
                },
                .STR(s) => {
                    if (k < 0 || k >= @cast<i128>(s.len())) {
                        return fail(span, fmt2("index {} out of bounds (len {})", num(k), unum(@cast<u64>(s.len()))));
                    }
                    return cval::INT(@cast<i128>(s.as_str()[@cast<usize>(k)]), U8);
                },
                default => { return fails(span, "can't index this at compile time"); },
            }
        },
        .CALL(callee, args&) => { return this.ct_call_expr(callee, args, want, span); },
        .BUILTIN(name, gargs&, args) => {
            val none: std::vec<garg> = {};
            if (args) {
                return this.ct_builtin(name, gargs, &args, want, span);
            }
            return this.ct_builtin(name, gargs, &none, want, span);
        },
        .RETURN(x) => {
            var v = cval::VOID;
            if (x) {
                v = try this.ct_expr(x, null);
            }
            return this.ct_leave(flow::RET(move v), span);
        },
        .BREAK(l, x) => {
            var v: cval? = null;
            if (x) {
                v = try this.ct_expr(x, null);
            }
            return this.ct_leave(flow::BRK(l, move v), span);
        },
        .CONTINUE(l) => { return this.ct_leave(flow::CONT(l), span); },
        .BLOCK(label, b&) => {
            val fl = try this.flow_of(this.ct_block(b));
            if (fl == null) {
                return cval::VOID;
            }
            match (fl.value) {
                .BRK(l, v) => {
                    if (l != null && label != null && (l ?? "") == (label ?? "")) {
                        if (v) {
                            return copy v;
                        }
                        return cval::VOID;
                    }
                },
                default => {},
            }
            return this.ct_leave(copy fl.value, span);
        },
        .IF(n&) => {
            if (try this.ct_bool(n.cond)) {
                try this.ct_block(&n.then);
            } else if (n.els) {
                try this.ct_expr(n.els, null);
            }
            return cval::VOID;
        },
        .LOOP(label, b&) => {
            while (true) {
                val fl = try this.flow_of(this.ct_block(b));
                if (fl == null) {
                    continue;
                }
                match (fl.value) {
                    .BRK(l, v) => {
                        if (is_mine(l, label)) {
                            if (v) {
                                return copy v;
                            }
                            return cval::VOID;
                        }
                    },
                    .CONT(l) => {
                        if (is_mine(l, label)) {
                            continue;
                        }
                    },
                    default => {},
                }
                return this.ct_leave(copy fl.value, span);
            }
            return cval::VOID;
        },
        .WHILE(label, c, b&) => {
            while (try this.ct_bool(c)) {
                val fl = try this.flow_of(this.ct_block(b));
                if (fl == null) {
                    continue;
                }
                match (fl.value) {
                    .BRK(l, v) => {
                        if (is_mine(l, label)) {
                            break;
                        }
                    },
                    .CONT(l) => {
                        if (is_mine(l, label)) {
                            continue;
                        }
                    },
                    default => {},
                }
                return this.ct_leave(copy fl.value, span);
            }
            return cval::VOID;
        },
        .FOR(f) => { return this.ct_for(f, span); },
        .MATCH(m) => {
            val v = try this.ct_expr(m.scrut, null);
            for (a&) in m.arms.items() {
                put(&this.ct_top().scopes, {});
                val r = this.ct_arm(a, &v, want);
                this.ct_top().scopes.pop();
                val out = try r;
                if (out) {
                    return copy out;
                }
            }
            return fails(span, "no match arm matched at compile time");
        },
        .OR_ELSE(a, b) => {
            val v = try this.ct_expr(a, null);
            match (v) {
                .OPT(t, x) => {
                    if (x) {
                        return copy *x.ptr;
                    }
                    return this.ct_expr(b, want);
                },
                .NULL => { return this.ct_expr(b, want); },
                default => { return v; },
            }
        },
        .MOVE(x) => { return this.ct_expr(x, want); },
        .COPY(x) => { return this.ct_expr(x, want); },
        .RANGE(lo, hi, incl) => { return fails(span, "ranges only work in for loops at compile time"); },
        default => { return fails(span, "this isn't supported at compile time"); },
    }
}

// one comptime match arm: its value when it matched
attach fn ct_arm(this: checker&, a: arm&, v: cval&, want: u32?) -> compile_error!(cval?) {
    if (!(try this.ct_pat(&a.pat, v))) {
        return null;
    }
    if (a.guard) {
        if (!(try this.ct_bool(&a.guard))) {
            return null;
        }
    }
    return try this.ct_expr(&a.body, want);
}

// a condition: a bool, or an optional (present?)
attach fn ct_bool(this: checker&, e: expr&) -> compile_error!bool {
    val v = try this.ct_expr(e, BOOL);
    match (v) {
        .BOOL(b) => { return b; },
        .OPT(t, x) => { return x != null; },
        default => { return fails(e.span, "expected a bool"); },
    }
}

// a binary op on two values; an int meeting a float becomes a float, and any two values compare with
// == and !=
attach fn ct_binop(this: checker&, op: binop, a: cval, b: cval, span: span) -> compile_error!cval {
    match (a) {
        .INT(x, ta) => {
            match (b) {
                .INT(y, tb) => { return this.ct_int_op(op, x, ta, y, tb, span); },
                .FLOAT(f, tb) => { return this.ct_binop(op, cval::FLOAT(@cast<f64>(x), VOID), copy b, span); },
                default => {},
            }
        },
        .FLOAT(x, ta) => {
            match (b) {
                .FLOAT(y, tb) => {
                    var t = ta;
                    if (t == VOID) {
                        t = tb;
                    }
                    if (op == binop::ADD) { return cval::FLOAT(x + y, t); }
                    if (op == binop::SUB) { return cval::FLOAT(x - y, t); }
                    if (op == binop::MUL) { return cval::FLOAT(x * y, t); }
                    if (op == binop::DIV) { return cval::FLOAT(x / y, t); }
                    if (op == binop::EQ) { return cval::BOOL(x == y); }
                    if (op == binop::NE) { return cval::BOOL(x != y); }
                    if (op == binop::LT) { return cval::BOOL(x < y); }
                    if (op == binop::GT) { return cval::BOOL(x > y); }
                    if (op == binop::LE) { return cval::BOOL(x <= y); }
                    if (op == binop::GE) { return cval::BOOL(x >= y); }
                    return fails(span, "this operator doesn't work on floats");
                },
                .INT(y, tb) => { return this.ct_binop(op, copy a, cval::FLOAT(@cast<f64>(y), VOID), span); },
                default => {},
            }
        },
        default => {},
    }
    if (op == binop::EQ || op == binop::NE) {
        var same = false;
        match (a) {
            .NULL => {
                match (b) {
                    .OPT(t, v) => { same = v == null; },
                    default => { same = cval_eq(&a, &b); },
                }
            },
            .OPT(t, v) => {
                match (b) {
                    .NULL => { same = v == null; },
                    default => { same = cval_eq(&a, &b); },
                }
            },
            default => { same = cval_eq(&a, &b); },
        }
        return cval::BOOL(same == (op == binop::EQ));
    }
    return fails(span, "can't use this operator on these values at compile time");
}

// ints must share a type (an untyped literal takes the other's) and fit it; wrapping ops wrap to the
// type's width (32 bits when untyped)
attach fn ct_int_op(this: checker&, op: binop, x: i128, ta: u32, y: i128, tb: u32, span: span) -> compile_error!cval {
    var t = ta;
    if (t == VOID) {
        t = tb;
    }
    if (ta != VOID && tb != VOID && ta != tb) {
        return type_diff(fail(span, fmt2("mismatched types {} and {}", this.ty_name(ta), this.ty_name(tb))));
    }
    val k = this.t.int_of(t);
    var r: i128? = null;
    if (op == binop::ADD) {
        r = add_i128(x, y);
    } else if (op == binop::SUB) {
        r = sub_i128(x, y);
    } else if (op == binop::MUL) {
        r = mul_i128(x, y);
    } else if (op == binop::DIV) {
        r = div_i128(x, y);
    } else if (op == binop::REM) {
        r = rem_i128(x, y);
    } else if (op == binop::WADD || op == binop::WSUB || op == binop::WMUL) {
        var w: i128 = 0;
        if (op == binop::WADD) {
            w = x +% y;
        } else if (op == binop::WSUB) {
            w = x -% y;
        } else {
            w = x *% y;
        }
        var bits: u32 = 32;
        var signed = true;
        if (k) {
            val kk = k;
            bits = kk.bits();
            signed = kk.signed();
        }
        r = wrap_bits(w, bits, signed);
    } else if (op == binop::BITAND) {
        r = x & y;
    } else if (op == binop::BITOR) {
        r = x | y;
    } else if (op == binop::BITXOR) {
        r = x ^ y;
    } else if (op == binop::SHL) {
        r = shl_i128(x, y);
    } else if (op == binop::SHR) {
        r = shr_i128(x, y);
    } else if (op == binop::EQ) {
        return cval::BOOL(x == y);
    } else if (op == binop::NE) {
        return cval::BOOL(x != y);
    } else if (op == binop::LT) {
        return cval::BOOL(x < y);
    } else if (op == binop::GT) {
        return cval::BOOL(x > y);
    } else if (op == binop::LE) {
        return cval::BOOL(x <= y);
    } else if (op == binop::GE) {
        return cval::BOOL(x >= y);
    }
    val v = r ?? return fails(span, "integer overflow or division by zero at compile time");
    if (k) {
        val kk = k;
        if (!kk.fits(v)) {
            return fail(span, fmt2("integer overflow at compile time: {} doesn't fit in {}", num(v), S(kk.name())));
        }
    }
    return cval::INT(v, t);
}

// structural equality of two compile-time values
fn cval_eq(a: cval&, b: cval&) -> bool {
    match (*a) {
        .VOID => {
            match (*b) {
                .VOID => { return true; },
                default => { return false; },
            }
        },
        .NULL => {
            match (*b) {
                .NULL => { return true; },
                default => { return false; },
            }
        },
        .BOOL(x) => {
            match (*b) {
                .BOOL(y) => { return x == y; },
                default => { return false; },
            }
        },
        .INT(x, t) => {
            match (*b) {
                .INT(y, u) => { return x == y && t == u; },
                default => { return false; },
            }
        },
        .FLOAT(x, t) => {
            match (*b) {
                .FLOAT(y, u) => { return x == y && t == u; },
                default => { return false; },
            }
        },
        .STR(x) => {
            match (*b) {
                .STR(y) => { return x.as_str() == y.as_str(); },
                default => { return false; },
            }
        },
        .TYPE(x) => {
            match (*b) {
                .TYPE(y) => { return x == y; },
                default => { return false; },
            }
        },
        .TUPLE(xs&) => {
            match (*b) {
                .TUPLE(ys&) => { return cvals_eq(xs, ys); },
                default => { return false; },
            }
        },
        .ARRAY(xs&, t) => {
            match (*b) {
                .ARRAY(ys&, u) => { return t == u && cvals_eq(xs, ys); },
                default => { return false; },
            }
        },
        .STRUCT(t, xs) => {
            match (*b) {
                .STRUCT(u, ys) => {
                    if (t != u || xs.len != ys.len) {
                        return false;
                    }
                    for (i) in 0..xs.len {
                        if (xs.at(i).name != ys.at(i).name || !cval_eq(&xs.at(i).v, &ys.at(i).v)) {
                            return false;
                        }
                    }
                    return true;
                },
                default => { return false; },
            }
        },
        .VARIANT(t, n, p) => {
            match (*b) {
                .VARIANT(u, m, q) => {
                    if (t != u || n != m || (p == null) != (q == null)) {
                        return false;
                    }
                    return p == null || cval_eq(p.value, q.value);
                },
                default => { return false; },
            }
        },
        .OPT(t, p) => {
            match (*b) {
                .OPT(u, q) => {
                    if (t != u || (p == null) != (q == null)) {
                        return false;
                    }
                    return p == null || cval_eq(p.value, q.value);
                },
                default => { return false; },
            }
        },
    }
}

fn cvals_eq(a: std::vec<cval>&, b: std::vec<cval>&) -> bool {
    if (a.len != b.len) {
        return false;
    }
    for (i) in 0..a.len {
        if (!cval_eq(a.at(i), b.at(i))) {
            return false;
        }
    }
    return true;
}

// an explicit conversion (`as`); with unchecked (@cast) an int wraps to fit and a float truncates
attach fn ct_convert(this: checker&, v: cval, to: u32, unchecked: bool, span: span) -> compile_error!cval {
    val tt = copy *this.t.get(to);
    match (v) {
        .INT(x, from) => {
            match (tt) {
                .INT(k) => {
                    if (!k.fits(x)) {
                        if (!unchecked) {
                            return fail(span, fmt2("{} doesn't fit in {}", num(x), S(k.name())));
                        }
                        return cval::INT(wrap_bits(x, k.bits(), k.signed()), to);
                    }
                    return cval::INT(x, to);
                },
                .FLOAT(b) => { return cval::FLOAT(@cast<f64>(x), to); },
                default => {},
            }
        },
        .FLOAT(x, from) => {
            match (tt) {
                .FLOAT(b) => { return cval::FLOAT(x, to); },
                .INT(k) => {
                    if (unchecked) {
                        return cval::INT(@cast<i128>(x), to);
                    }
                },
                default => {},
            }
        },
        .BOOL(b) => {
            match (tt) {
                .INT(k) => {
                    if (b) {
                        return cval::INT(1, to);
                    }
                    return cval::INT(0, to);
                },
                default => {},
            }
        },
        .VARIANT(t, n, p) => {
            match (tt) {
                .INT(k) => {
                    if (p == null) {
                        // typeinfo kinds (BOOL, VOID, ...) are variants of no real enum
                        val eid = this.enum_of(t) ?? return fail(span, fmt("can't cast .{} to an integer", S(n)));
                        val i = this.variant_index(eid, n) ?? 0;
                        return cval::INT(*this.ei(eid).values.at(i), to);
                    }
                },
                default => {},
            }
        },
        default => {},
    }
    return this.ct_coerce(move v, to, span);
}

// the variable an assignment place is rooted at
fn ct_root(e: expr&) -> str? {
    match (e.kind) {
        .PATH(p) => {
            if (p.is_single()) {
                return p.segs.at(0).name;
            }
            return null;
        },
        .FIELD(b, n, g) => { return ct_root(b); },
        .INDEX(b, i) => { return ct_root(b); },
        default => { return null; },
    }
}

// `place op= value` inside the interpreter
attach fn ct_store(this: checker&, place: expr&, op: binop?, v: cval, span: span) -> compile_error!void {
    val name = ct_root(place) ?? return fails(span, "can't assign to this at compile time");
    var whole = this.ct_lookup(name) ?? return fail(span, fmt("'{}' isn't a compile-time variable", S(name)));
    var nv = move v;
    if (op) {
        val cur = try this.ct_expr(place, null);
        nv = try this.ct_binop(op, move cur, move nv, span);
    }
    try this.ct_write(&whole, place, move nv, span);
    return this.ct_set(name, move whole, span);
}

// stores v at place inside whole (the root variable's value), rebuilding each parent on the way up
attach fn ct_write(this: checker&, whole: cval&, place: expr&, v: cval, span: span) -> compile_error!void {
    match (place.kind) {
        .PATH(p) => {
            val t = this.ct_type_of(whole);
            var is_void = false;
            match (*whole) {
                .VOID => { is_void = true; },
                default => {},
            }
            if (is_void || t == VOID) {
                *whole = copy v;
            } else {
                *whole = try this.ct_coerce(copy v, t, span);
            }
        },
        .FIELD(b, name, g) => {
            var parent = try this.ct_expr(b, null);
            var set = false;
            match (parent) {
                .STRUCT(t, fields) => {
                    for (f&) in fields.items() {
                        if (f.name == name) {
                            f.v = copy v;
                            set = true;
                        }
                    }
                },
                .TUPLE(es) => {
                    val i = parse_index(name);
                    if (i != null && (i ?? 0) < es.len) {
                        *es.at(i ?? 0) = copy v;
                        set = true;
                    }
                },
                default => { return fails(span, "can't assign a field of this at compile time"); },
            }
            if (!set) {
                return fail(span, fmt("no field '{}'", S(name)));
            }
            try this.ct_write(whole, b, move parent, span);
        },
        .INDEX(b, ix) => {
            var parent = try this.ct_expr(b, null);
            val iv = try this.ct_expr(ix, USIZE);
            var i: i128 = 0;
            match (iv) {
                .INT(x, t) => { i = x; },
                default => { return fails(span, "index must be an integer"); },
            }
            match (parent) {
                .ARRAY(es, t) => {
                    if (i < 0 || i >= @cast<i128>(es.len)) {
                        return fail(span, fmt("index {} out of bounds", num(i)));
                    }
                    *es.at(@cast<usize>(i)) = copy v;
                },
                default => { return fails(span, "can't index this at compile time"); },
            }
            try this.ct_write(whole, b, move parent, span);
        },
        default => { return fails(span, "can't assign to this at compile time"); },
    }
}


// `{ ... }` at compile time: a struct or array of the wanted type, or an untyped list when none is wanted
// the most elements a { x; n } or {} makes at compile time (each is a value in memory)
val CT_ARRAY_MAX: u64 = 1048576;

// `{ x; n }` at compile time: an array of the wanted type, or an untyped list when none is wanted
attach fn ct_repeat(this: checker&, x: expr&, n: expr&, want: u32?, span: span) -> compile_error!cval {
    // inside an optional: the array, present
    if (want) {
        val inner = this.t.opt_inner(want);
        if (inner) {
            val v = try this.ct_repeat(x, n, inner, span);
            return cval::OPT(want, some_c(move v));
        }
    }
    var count: i128 = -1;
    match (try this.ct_expr(n, null)) {
        .INT(c, t) => { count = c; },
        default => {},
    }
    if (count < 0) {
        return fails(n.span, "a repeat count is an integer, 0 or more");
    }
    if (count > @cast<i128>(CT_ARRAY_MAX)) {
        return fail(span, fmt("a repeat at compile time makes at most {} elements", unum(CT_ARRAY_MAX)));
    }
    var et = VOID;
    var v = cval::VOID;
    if (want) {
        match (*this.t.get(want)) {
            .ARRAY(t, len) => {
                if (count != @cast<i128>(len)) {
                    return fail(span, fmt2("this repeats {} times but the array holds {}", num(count), unum(len)));
                }
                et = t;
            },
            default => { return fails(span, "a { x; n } literal makes an array"); },
        }
        val x0 = try this.ct_expr(x, et);
        v = try this.ct_coerce(move x0, et, span);
    } else {
        v = try this.ct_expr(x, null); // untyped, as a { a, b } list is
    }
    var es: std::vec<cval> = {};
    for (i) in 0..count {
        put(&es, copy v);
    }
    return cval::ARRAY(move es, et);
}

// the value a `var x: T;` starts with, at compile time (what `{}` makes for an array)
attach fn ct_zero(this: checker&, t: u32, span: span) -> compile_error!cval {
    match (*this.t.get(t)) {
        .INT(k) => { return cval::INT(0, t); },
        .FLOAT(b) => { return cval::FLOAT(0.0, t); },
        .BOOL => { return cval::BOOL(false); },
        .OPT(x) => { return cval::OPT(t, null); },
        .ARRAY(et, n) => {
            if (n > CT_ARRAY_MAX) {
                return fail(span, fmt("an array at compile time holds at most {} elements", unum(CT_ARRAY_MAX)));
            }
            var es: std::vec<cval> = {};
            for (i) in 0..n {
                put(&es, try this.ct_zero(et, span));
            }
            return cval::ARRAY(move es, et);
        },
        .TUPLE(ts, names) => {
            val xs = copy ts;
            var es: std::vec<cval> = {};
            for (x&) in xs.items() {
                put(&es, try this.ct_zero(*x, span));
            }
            return cval::TUPLE(move es);
        },
        .STRUCT(sid) => {
            if (!this.header_struct(sid)) {
                val nf = (try this.struct_fields(sid, span)).len;
                var out: std::vec<cfield> = {};
                for (k) in 0..nf {
                    val f = *(try this.struct_fields(sid, span)).at(k);
                    var v = cval::VOID;
                    if (f.fallback) {
                        val d = try this.ct_eval_in(this.si(sid).env, f.fallback, f.ty);
                        v = try this.ct_coerce(move d, f.ty, span);
                    } else {
                        v = try this.ct_zero(f.ty, span);
                    }
                    put(&out, { name: f.name, v: move v });
                }
                return cval::STRUCT(t, move out);
            }
        },
        default => {},
    }
    return fail(span, fmt("a {} has no zero value at compile time", this.ty_name(t)));
}

attach fn ct_literal(this: checker&, entries: std::vec<lit_entry>&, want: u32?, span: span) -> compile_error!cval {
    if (want == null) {
        var es: std::vec<cval> = {};
        for (en&) in entries.items() {
            put(&es, try this.ct_expr(&en.value, null));
        }
        return cval::ARRAY(move es, VOID);
    }
    val w = want ?? 0;
    match (*this.t.get(w)) {
        .STRUCT(sid) => {
            val nf = (try this.struct_fields(sid, span)).len;
            var out: std::vec<cfield> = {};
            for (k) in 0..nf {
                val f = *(try this.struct_fields(sid, span)).at(k);
                var given: expr* = null;
                for (en&) in entries.items() {
                    if (en.name != null && (en.name ?? "") == f.name) {
                        given = &en.value;
                    } else if (en.name == null) {
                        match (en.value.kind) {
                            .PATH(p) => {
                                if (p.is_single() && p.segs.at(0).name == f.name) {
                                    given = &en.value;
                                }
                            },
                            default => {},
                        }
                    }
                }
                var v = cval::VOID;
                if (given) {
                    v = try this.ct_expr(given, f.ty);
                } else if (f.fallback) {
                    v = try this.ct_eval_in(this.si(sid).env, f.fallback, f.ty);
                } else if (this.t.opt_inner(f.ty) != null) {
                    v = cval::OPT(f.ty, null);
                } else {
                    return fail(span, fmt("missing field '{}'", S(f.name)));
                }
                put(&out, { name: f.name, v: try this.ct_coerce(move v, f.ty, span) });
            }
            return cval::STRUCT(w, move out);
        },
        .ARRAY(et, n) => {
            if (entries.len == 0) {
                return this.ct_zero(w, span); // {}: all zero
            }
            if (@cast<u64>(entries.len) != n) {
                return fail(span, fmt2("expected {} elements, found {}", unum(n), unum(@cast<u64>(entries.len))));
            }
            var es: std::vec<cval> = {};
            for (en&) in entries.items() {
                val v = try this.ct_expr(&en.value, et);
                put(&es, try this.ct_coerce(move v, et, span));
            }
            return cval::ARRAY(move es, et);
        },
        default => { return fail(span, fmt("a {{ }} literal can't make a {} at compile time", this.ty_name(w))); },
    }
}

// field access at compile time; `.len`, `.none`/`.value`, and a type's fields are its typeinfo's
attach fn ct_field(this: checker&, v: cval, name: str, span: span) -> compile_error!cval {
    match (v) {
        .STRUCT(t, fields) => {
            for (f&) in fields.items() {
                if (f.name == name) {
                    return copy f.v;
                }
            }
            return fail(span, fmt("no field '{}'", S(name)));
        },
        .TUPLE(es) => {
            val i = parse_index(name);
            if (i != null && (i ?? 0) < es.len) {
                return copy *es.at(i ?? 0);
            }
            return fail(span, fmt("no field '{}'", S(name)));
        },
        .STR(s) => {
            if (name == "len") {
                return cval::INT(@cast<i128>(s.len()), USIZE);
            }
        },
        .ARRAY(es, t) => {
            if (name == "len") {
                return cval::INT(@cast<i128>(es.len), USIZE);
            }
        },
        .OPT(t, x) => {
            if (name == "none") {
                return cval::BOOL(x == null);
            }
            if (name == "value" && x != null) {
                return copy *x.value.ptr;
            }
        },
        .TYPE(t) => {
            // a type's fields are its typeinfo's
            val ti = try this.typeinfo(t, span);
            return this.ct_field(move ti, name, span);
        },
        default => {},
    }
    return fail(span, fmt("no field '{}' at compile time", S(name)));
}

// runs a block in a scope of its own
attach fn ct_block(this: checker&, b: block&) -> compile_error!void {
    try this.ct_step(b.span); // counts loop iterations even when the body is empty
    put(&this.ct_top().scopes, {});
    val r = this.ct_stmts(b);
    this.ct_top().scopes.pop();
    return r;
}

attach fn ct_stmts(this: checker&, b: block&) -> compile_error!void {
    for (s&) in b.stmts.items() {
        try this.ct_stmt(s);
    }
}

// a let or an expression statement; defer, suspend and resume can't run at compile time
attach fn ct_stmt(this: checker&, s: stmt&) -> compile_error!void {
    match (s.kind) {
        .LET(l&) => { return this.ct_let_stmt(l); },
        .EXPR(e&) => {
            try this.ct_expr(e, null);
            return;
        },
        default => { return fails(s.span, "defer/suspend/resume don't run at compile time"); },
    }
}

// `val`/`var` in the interpreter: binds a name or a tuple of names in the current scope
attach fn ct_let_stmt(this: checker&, l: let_stmt&) -> compile_error!void {
    var t: u32? = null;
    if (l.ty) {
        var open_array = false;
        match (l.ty.kind) {
            .ARRAY(x, n) => { open_array = n == null; },
            default => {},
        }
        if (!open_array) {
            t = try this.resolve_type(&l.ty, this.ct_top().env);
        }
    }
    var v = cval::VOID;
    if (l.init) {
        v = try this.ct_expr(&l.init, t);
        if (t) {
            v = try this.ct_coerce(move v, t, l.init.span);
        }
    }
    match (l.pat.kind) {
        .BIND(n) => { this.ct_scope().put(n, { value: copy v, mutable: l.mutable }); },
        .TUPLE(ps) => {
            match (v) {
                .TUPLE(es) => {
                    for (i) in 0..ps.len {
                        if (i >= es.len) {
                            break;
                        }
                        match (ps.at(i).kind) {
                            .BIND(n) => { this.ct_scope().put(n, { value: copy *es.at(i), mutable: l.mutable }); },
                            default => {},
                        }
                    }
                },
                default => { return fails(l.span, "expected a tuple"); },
            }
        },
        default => { return fails(l.span, "unsupported pattern at compile time"); },
    }
}

// a for loop over a range, list, tuple or string; with an accumulator, its final value is the loop's
attach fn ct_for(this: checker&, f: for_loop&, span: span) -> compile_error!cval {
    var items: std::vec<cval> = {};
    var ranged = false;
    match (f.iter.kind) {
        .RANGE(lo, hi, incl) => {
            if (lo != null && hi != null) {
                ranged = true;
                val a = try this.ct_expr(lo.value, null);
                val b = try this.ct_expr(hi.value, null);
                var x: i128 = 0;
                var y: i128 = 0;
                var t = VOID;
                match (a) {
                    .INT(v, vt) => {
                        x = v;
                        t = vt;
                    },
                    default => { return fails(span, "ranges need integers"); },
                }
                match (b) {
                    .INT(v, vt) => { y = v; },
                    default => { return fails(span, "ranges need integers"); },
                }
                var end = y;
                if (incl) {
                    end = y + 1;
                }
                if (end - x > 10000000) {
                    return fails(span, "compile-time range is too long");
                }
                var i = x;
                while (i < end) {
                    put(&items, cval::INT(i, t));
                    i += 1;
                }
            }
        },
        default => {},
    }
    if (!ranged) {
        val v = try this.ct_expr(&f.iter, null);
        match (v) {
            .ARRAY(es, t) => { items = copy es; },
            .TUPLE(es) => { items = copy es; },
            .STR(s) => {
                for (c) in s.as_str() {
                    put(&items, cval::INT(@cast<i128>(c), U8));
                }
            },
            default => { return fails(f.iter.span, "can't loop over this at compile time"); },
        }
    }
    var acc: str? = null;
    if (f.acc) {
        put(&this.ct_top().scopes, {});
        val r = this.ct_let_stmt(&f.acc);
        r catch |e| {
            this.ct_top().scopes.pop();
            return copy e;
        };
        match (f.acc.pat.kind) {
            .BIND(n) => { acc = n; },
            default => {},
        }
    }
    val r = this.ct_for_items(f, move items);
    var out = cval::VOID;
    if (acc) {
        out = this.ct_lookup(acc) ?? cval::VOID;
    }
    if (f.acc) {
        this.ct_top().scopes.pop();
    }
    try r;
    return out;
}

// runs the body once per item, each in its own scope, until a break
attach fn ct_for_items(this: checker&, f: for_loop&, items: std::vec<cval>) -> compile_error!void {
    for (i) in 0..items.len {
        put(&this.ct_top().scopes, {});
        val r = this.ct_for_body(f, copy *items.at(i), i);
        this.ct_top().scopes.pop();
        val fl = try this.flow_of(r);
        if (fl == null) {
            continue;
        }
        match (fl.value) {
            .BRK(l, v) => {
                if (is_mine(l, f.label)) {
                    return;
                }
            },
            .CONT(l) => {
                if (is_mine(l, f.label)) {
                    continue;
                }
            },
            default => {},
        }
        return this.ct_leave(copy fl.value, f.body.span);
    }
}

// binds the element (or its `=> map` value) and index, then runs the body
attach fn ct_for_body(this: checker&, f: for_loop&, item: cval, i: usize) -> compile_error!void {
    val sc = this.ct_scope();
    sc.put(f.bindings.at(0).name, { value: move item, mutable: false });
    if (f.bindings.len > 1) {
        sc.put(f.bindings.at(1).name, { value: cval::INT(@cast<i128>(i), USIZE), mutable: false });
    }
    if (f.map) {
        val v = try this.ct_expr(&f.map, null);
        this.ct_scope().put(f.bindings.at(0).name, { value: move v, mutable: false });
    }
    return this.ct_block(&f.body);
}

// whether v matches p, binding names into the current scope
attach fn ct_pat(this: checker&, p: pat&, v: cval&) -> compile_error!bool {
    match (p.kind) {
        .WILD => { return true; },
        .BIND_REF(n) => {
            this.ct_scope().put(n, { value: copy *v, mutable: false });
            return true;
        },
        .BIND(n) => {
            // a bare name that is one of the enum's variants tests for it (as at runtime) instead of binding
            match (*v) {
                .VARIANT(t, vn, payload) => {
                    val eid = this.enum_of(t);
                    if (eid) {
                        if (this.variant_index(eid, n) != null) {
                            return vn == n;
                        }
                    }
                },
                default => {},
            }
            this.ct_scope().put(n, { value: copy *v, mutable: false });
            return true;
        },
        .LIT(e&) => {
            val t = this.ct_type_of(v);
            val lv = try this.ct_expr(e, t);
            val r = try this.ct_binop(binop::EQ, copy *v, move lv, p.span);
            match (r) {
                .BOOL(b) => { return b; },
                default => { return false; },
            }
        },
        .RANGE(lo&, hi&, incl) => {
            val a = try this.ct_expr(lo, null);
            val b = try this.ct_expr(hi, null);
            var x: i128 = 0;
            var y: i128 = 0;
            var z: i128 = 0;
            var ok = true;
            match (a) {
                .INT(q, t) => { x = q; },
                default => { ok = false; },
            }
            match (b) {
                .INT(q, t) => { y = q; },
                default => { ok = false; },
            }
            match (*v) {
                .INT(q, t) => { z = q; },
                default => { ok = false; },
            }
            if (!ok) {
                return fails(p.span, "range patterns need integers");
            }
            if (incl) {
                return z >= x && z <= y;
            }
            return z >= x && z < y;
        },
        .TUPLE(ps) => {
            match (*v) {
                .TUPLE(es) => {
                    if (es.len != ps.len) {
                        return false;
                    }
                    for (i) in 0..ps.len {
                        if (!(try this.ct_pat(ps.at(i), es.at(i)))) {
                            return false;
                        }
                    }
                    return true;
                },
                default => { return false; },
            }
        },
        .CTOR(path, args) => {
            var name: str = "";
            match (path) {
                .DOT(n) => { name = n; },
                .PATH(pp) => { name = pp.last(); },
            }
            match (*v) {
                .VARIANT(t, vn, payload) => {
                    if (vn != name) {
                        return false;
                    }
                    if (args == null) {
                        return true;
                    }
                    val ps = &args.value;
                    if (payload == null) {
                        return ps.len == 0;
                    }
                    val pv: cval& = payload.value;
                    if (ps.len == 1) {
                        return this.ct_pat(ps.at(0), pv);
                    }
                    match (*pv) {
                        .TUPLE(es) => {
                            if (es.len != ps.len) {
                                return false;
                            }
                            for (i) in 0..ps.len {
                                if (!(try this.ct_pat(ps.at(i), es.at(i)))) {
                                    return false;
                                }
                            }
                            return true;
                        },
                        default => { return false; },
                    }
                },
                default => { return false; },
            }
        },
    }
}

// ---------- calls ----------

// a call at compile time: a fn by name (overloads picked by arity, then by return type == want), or an
// enum variant with a payload
attach fn ct_call_expr(this: checker&, callee: expr&, args: std::vec<expr>&, want: u32?, span: span) -> compile_error!cval {
    var pp: path* = null;
    match (callee.kind) {
        .PATH(p&) => { pp = p; },
        .DOT_VARIANT(n) => {
            val t = this.dot_target(want) ?? return fail(span, fmt("can't tell which enum .{} belongs to", S(n)));
            val payload = try this.ct_payload(args);
            return cval::VARIANT(t, n, move payload);
        },
        default => { return fails(span, "only calls to named functions run at compile time"); },
    }
    val p = pp ?? return fails(span, "");
    val env = this.ct_top().env;
    val ns = this.env_at(env).ns;
    var f: found? = null;
    if (p.segs.len == 1) {
        f = this.lookup(ns, p.segs.at(0).name);
    } else {
        f = this.lookup_path_ns(ns, p);
    }
    var decls: std::vec<u32> = {};
    match (f ?? found::NS(0)) {
        .DECLS(l) => {
            if (f != null) {
                for (d&) in this.list(l).items() {
                    if (this.fn_decl_of(*d) != null) {
                        put(&decls, *d);
                    }
                }
            }
        },
        default => {},
    }
    if (decls.len == 0) {
        val m = try this.member_path(p);
        if (m) {
            match (m) {
                .OF(t, name) => {
                    if (this.enum_of(t) != null) {
                        val payload = try this.ct_payload(args);
                        return cval::VARIANT(t, name, move payload);
                    }
                },
                default => {},
            }
        }
        return fail(span, fmt("no function '{}' to call at compile time", S(p.last())));
    }
    var vals: std::vec<cval> = {};
    for (a&) in args.items() {
        put(&vals, try this.ct_expr(a, null));
    }
    // overloads: arity, then return type
    var cands: std::vec<u32> = {};
    for (d&) in decls.items() {
        val fd = this.fn_decl_of(*d) ?? continue;
        var n: usize = 0;
        var has_default = false;
        for (q&) in fd.params.items() {
            if (q.name != "this") {
                n += 1;
            }
            if (q.fallback != null) {
                has_default = true;
            }
        }
        if (n == vals.len || has_default) {
            put(&cands, *d);
        }
    }
    var pick: u32? = null;
    if (cands.len > 1) {
        for (d&) in cands.items() {
            val fd = this.fn_decl_of(*d) ?? continue;
            val renv = this.new_env({ ns: this.dl(*d).ns });
            var ret = VOID;
            if (fd.ret) {
                ret = this.resolve_type(&fd.ret, renv) catch |x| NO_TY;
            }
            if (want != null && ret == (want ?? NO_TY)) {
                pick = *d;
            }
        }
    }
    if (pick == null && cands.len > 0) {
        pick = *cands.at(0);
    }
    val d = pick ?? return fail(span, fmt2("no version of '{}' takes {} arguments", S(p.last()), unum(@cast<u64>(vals.len))));
    try this.visible(d, span);
    val last = p.segs.at(p.segs.len - 1);
    val none: std::vec<garg> = {};
    if (last.args) {
        return this.ct_call(d, &last.args, move vals, span);
    }
    return this.ct_call(d, &none, move vals, span);
}

// a variant's payload args: none, one value, or a tuple of several
attach fn ct_payload(this: checker&, args: std::vec<expr>&) -> compile_error!(std::box<cval>?) {
    if (args.len == 0) {
        return null;
    }
    if (args.len == 1) {
        val v = try this.ct_expr(args.at(0), null);
        return some_c(move v);
    }
    var es: std::vec<cval> = {};
    for (a&) in args.items() {
        put(&es, try this.ct_expr(a, null));
    }
    return some_c(cval::TUPLE(move es));
}

// interprets fn decl on args: binds its generics (explicit, then inferred from the args' types, then
// defaults), runs the body in a new frame and coerces the result to the return type
attach fn ct_call(this: checker&, decl: u32, explicit: std::vec<garg>&, args: std::vec<cval>, span: span) -> compile_error!cval {
    if (this.ct.len > MAX_DEPTH) {
        return fails(span, "compile-time calls nest too deep (over 256); is there endless recursion?");
    }
    val f = this.fn_decl_of(decl) ?? return fails(span, "not a function");
    if (f.body == null) {
        return fail(span, fmt("'{}' has no body, so it can't run at compile time", S(f.name)));
    }
    val ns = this.dl(decl).ns;
    val gps = this.fn_generics(decl);
    var binds = none_binds(gps.len);
    val caller = this.ct_top().env;
    for (i) in 0..explicit.len {
        if (i < gps.len) {
            val pe = this.partial_env(ns, gps, &binds);
            val kind = try this.param_kind(gps.at(i), pe);
            *binds.at(i) = try this.garg_gval(explicit.at(i), kind, caller);
        }
    }
    // infer the rest from the argument values' types, then fall back to defaults
    var vparams: std::vec<param*> = {};
    for (q&) in f.params.items() {
        if (q.name != "this") {
            put(&vparams, q);
        }
    }
    for (i) in 0..vparams.len {
        if (i >= args.len) {
            break;
        }
        val q = *vparams.at(i) ?? continue;
        if (q.ty) {
            val t = this.ct_type_of(args.at(i));
            this.infer(&q.ty, t, gps, &binds, ns);
        }
    }
    for (i) in 0..gps.len {
        if (*binds.at(i) == null) {
            val pe = this.partial_env(ns, gps, &binds);
            val g = gps.at(i);
            val d = g.fallback ?? return fail(span, fmt2("can't infer '{}' for '{}' at compile time", S(g.name), S(f.name)));
            val kind = try this.param_kind(g, pe);
            *binds.at(i) = try this.garg_gval(d, kind, pe);
        }
    }
    var bs: std::vec<gval> = {};
    for (b&) in binds.items() {
        put(&bs, *b ?? gval::INT(0));
    }
    val env = this.inst_env(ns, gps, &bs);
    // the params, with defaults for missing args, are the new frame's first scope
    var sc: std::map<str, const_entry> = {};
    for (i) in 0..vparams.len {
        val q = *vparams.at(i) ?? continue;
        var v = cval::VOID;
        if (i < args.len) {
            v = copy *args.at(i);
        } else if (q.fallback) {
            v = try this.ct_eval_in(env, &q.fallback, null);
        } else {
            return fail(span, fmt("missing argument '{}'", S(q.name)));
        }
        if (q.ty) {
            val t = try this.resolve_type(&q.ty, env);
            v = try this.ct_coerce(move v, t, span);
        }
        sc.put(q.name, { value: move v, mutable: q.mutable });
    }
    var ret = VOID;
    if (f.ret) {
        ret = try this.resolve_type(&f.ret, env);
    }
    var fr: ct_frame = { scopes: {}, env: env };
    put(&fr.scopes, move sc);
    put(&this.ct, move fr);
    val r = this.ct_block(&f.body.value);
    this.ct.pop();
    var out = cval::VOID;
    val fl = try this.flow_of(r);
    if (fl) {
        match (fl) {
            .RET(v) => { out = copy v; },
            default => { return fails(span, "break/continue outside of a loop"); },
        }
    }
    if (ret == VOID || ret == TYPE) {
        return out;
    }
    return this.ct_coerce(move out, ret, span);
}

// ---------- builtins ----------

// a type argument: a comptime variable holding a type, a type expression, or a type written out
attach fn ct_ty_arg(this: checker&, g: garg&, env: u32) -> compile_error!u32 {
    match (*g) {
        .EXPR(e&) => {
            match (e.kind) {
                .PATH(p) => {
                    if (p.is_single()) {
                        val v = this.ct_lookup(p.segs.at(0).name);
                        if (v) {
                            match (v) {
                                .TYPE(t) => { return t; },
                                default => {},
                            }
                        }
                    }
                    return this.garg_type_env(g, env);
                },
                default => {
                    val v = try this.ct_expr(e, null);
                    match (v) {
                        .TYPE(t) => { return t; },
                        default => { return fails(e.span, "expected a type"); },
                    }
                },
            }
        },
        .TYPE(t) => {
            match (t.kind) {
                .PATH(p) => {
                    if (p.is_single()) {
                        val v = this.ct_lookup(p.segs.at(0).name);
                        if (v) {
                            match (v) {
                                .TYPE(x) => { return x; },
                                default => {},
                            }
                        }
                    }
                },
                default => {},
            }
            return this.garg_type_env(g, env);
        },
    }
}

// is a cfg entry ("KEY" or "KEY=VALUE") for one of the target's keys?
fn is_target_key(set: str) -> bool {
    var key = set;
    val eq = set.find("=");
    if (eq) {
        key = set[0..eq];
    }
    return key == "os" || key == "arch" || key == "pointer_bits";
}

// the value --cfg KEY=VALUE gives a target key, for any package
attach fn cfg_given(this: checker&, key: str) -> str? {
    for (c&) in this.opts.cfg.items() {
        if (c.set.len > key.len && c.set[0..key.len] == key && c.set[key.len] == '=') {
            return c.set[key.len + 1..c.set.len];
        }
    }
    return null;
}

// does a set cfg entry ("KEY" or "KEY=VALUE") answer @cfg's want? A key alone matches KEY and
// KEY=anything
fn cfg_matches(set: str, want: str, key_only: bool) -> bool {
    return set == want || (key_only && set.len > want.len && set[0..want.len] == want && set[want.len] == '=');
}

// @typeinfo, @typeid, @typeof, @compile_error, @cfg, @attaches, @sizeof, @alignof, @cast and @panic at compile time
attach fn ct_builtin(this: checker&, name: str, gargs: std::vec<garg>&, args: std::vec<garg>&, want: u32?, span: span) -> compile_error!cval {
    val env = this.ct_top().env;
    if (name == "typeinfo") {
        if (args.len != 1) {
            return fails(span, "@typeinfo(T) takes one type");
        }
        val t = try this.ct_ty_arg(args.at(0), env);
        return this.typeinfo(t, span);
    }
    if (name == "typeid") {
        if (args.len != 1) {
            return fails(span, "@typeid takes one type or value");
        }
        var t = this.ct_ty_arg(args.at(0), env) catch |x| NO_TY;
        if (t == NO_TY) {
            // a compile-time value: its type's id
            val e = try this.garg_value(args.at(0));
            val v = try this.ct_expr(e, null);
            t = this.ct_type_of(&v);
        }
        return cval::INT(@cast<i128>(this.type_id(t)), int_id(int_ty::U64));
    }
    if (name == "typeof") {
        if (args.len != 1) {
            return fails(span, "@typeof(x) takes one value");
        }
        var e: expr* = null;
        match (*args.at(0)) {
            .EXPR(x&) => { e = x; },
            .TYPE(t) => {
                match (t.kind) {
                    .PATH(p) => { e = this.keep_expr({ kind: expr_kind::PATH(copy p), span: t.span }); },
                    default => { return fails(t.span, "expected a value"); },
                }
            },
        }
        val x = e ?? return fails(span, "");
        // compile-time values have types; runtime expressions are type checked (not run)
        if (this.ct.len == 1 && !this.is_ct_expr(x)) {
            match (x.kind) {
                .PATH(p) => {
                    if (p.is_single() && this.ct_lookup(p.segs.at(0).name) == null) {
                        val l = this.lookup_local(p.segs.at(0).name);
                        if (l) {
                            return cval::TYPE(l.ty);
                        }
                    }
                },
                default => {},
            }
        }
        val v = try this.ct_expr(x, null);
        return cval::TYPE(this.ct_type_of(&v));
    }
    if (name == "cfg") {
        // @cfg(KEY) / @cfg(KEY, VALUE): was --cfg KEY[=VALUE] given for the package this is written in,
        // or is it one of the target's keys (os, arch, pointer_bits)?
        var parts: std::vec<std::string> = {};
        for (a&) in args.items() {
            match (*a) {
                .EXPR(x&) => {
                    val v = try this.ct_expr(x, null);
                    match (v) {
                        .STR(s) => { put(&parts, copy s); },
                        default => { return fails(x.span, "@cfg takes strings: @cfg(\"feature\", \"name\")"); },
                    }
                },
                .TYPE(t) => { return fails(t.span, "@cfg takes strings: @cfg(\"feature\", \"name\")"); },
            }
        }
        return cval::BOOL(try this.cfg_on(&parts, span));
    }
    if (name == "compile_error") {
        var msg = S("compile error");
        if (args.len > 0) {
            match (*args.at(0)) {
                .EXPR(x&) => {
                    val v = try this.ct_expr(x, null);
                    match (v) {
                        .STR(s) => { msg = copy s; },
                        default => {},
                    }
                },
                default => {},
            }
        }
        return fail(span, move msg);
    }
    if (name == "attaches") {
        // @attaches(T, some_trait): does T attach the trait (as a <T: some_trait> bound asks)?
        if (args.len != 2) {
            return fails(span, "@attaches(T, trait) takes a type and a trait");
        }
        val t = try this.ct_ty_arg(args.at(0), env);
        var bound: ty* = null;
        match (*args.at(1)) {
            .TYPE(b&) => { bound = b; },
            .EXPR(e&) => {
                match (e.kind) {
                    .PATH(p) => { bound = this.keep_ty({ kind: type_kind::PATH(copy p), span: e.span }); },
                    default => { return fails(e.span, "@attaches(T, trait): expected a trait"); },
                }
            },
        }
        val b = bound ?? return fails(span, "@attaches(T, trait): expected a trait");
        val tr = this.bound_trait(b, this.env_at(env).ns) ?? return fails(b.span, "@attaches(T, trait): expected a trait");
        return cval::BOOL(try this.satisfies(t, tr.decl, tr.args, env));
    }
    if (name == "has_method") {
        // @has_method(T, "name", A...): does T have a method of that name (attached to it, by an
        // attach fn or an attach block), taking arguments of types A first?
        if (args.len < 2) {
            return fails(span, "@has_method(T, \"name\", A...) takes a type, a name and argument types");
        }
        val t = try this.ct_ty_arg(args.at(0), env);
        var tys: std::vec<u32> = {};
        for (i) in 2..args.len {
            put(&tys, try this.ct_ty_arg(args.at(i), env));
        }
        match (*args.at(1)) {
            .EXPR(e&) => {
                match (try this.ct_expr(e, null)) {
                    .STR(s) => { return cval::BOOL(this.has_method(t, s.as_str(), &tys)); },
                    default => {},
                }
                return fails(e.span, "@has_method(T, \"name\"): the name is a string");
            },
            .TYPE(b&) => { return fails(b.span, "@has_method(T, \"name\"): the name is a string"); },
        }
    }
    if (name == "has_field") {
        // @has_field(T, "name"): is T a struct with a field of that name?
        if (args.len != 2) {
            return fails(span, "@has_field(T, \"name\") takes a type and a name");
        }
        val t = try this.ct_ty_arg(args.at(0), env);
        var fname = S("");
        match (*args.at(1)) {
            .EXPR(e&) => {
                match (try this.ct_expr(e, null)) {
                    .STR(s) => { fname = copy s; },
                    default => { return fails(e.span, "@has_field(T, \"name\"): the name is a string"); },
                }
            },
            .TYPE(b&) => { return fails(b.span, "@has_field(T, \"name\"): the name is a string"); },
        }
        match (*this.t.get(t)) {
            .STRUCT(sid) => {
                for (f&) in (try this.struct_fields(sid, span)).items() {
                    if (f.name == fname.as_str()) {
                        return cval::BOOL(true);
                    }
                }
            },
            default => {},
        }
        return cval::BOOL(false);
    }
    if (name == "sizeof" || name == "alignof") {
        if (args.len != 1) {
            return fail(span, fmt("@{}(T) takes one type", S(name)));
        }
        val t = try this.ct_ty_arg(args.at(0), env);
        val l = try this.layout(t, span);
        if (name == "sizeof") {
            return cval::INT(@cast<i128>(l.size), USIZE);
        }
        return cval::INT(@cast<i128>(l.align), USIZE);
    }
    if (name == "cast") {
        if (gargs.len != 1 || args.len != 1) {
            return fails(span, "@cast<T>(x)");
        }
        val to = try this.garg_type_env(gargs.at(0), env);
        var v = cval::VOID;
        match (*args.at(0)) {
            .EXPR(x&) => { v = try this.ct_expr(x, null); },
            .TYPE(t) => {
                match (t.kind) {
                    .PATH(p&) => { v = try this.ct_path(p, null, t.span); },
                    default => { return fails(t.span, "expected a value"); },
                }
            },
        }
        return this.ct_convert(move v, to, true, span);
    }
    if (name == "panic") {
        return fails(span, "@panic reached at compile time");
    }
    return fail(span, fmt("@{} doesn't run at compile time", S(name)));
}

// ---------- typeinfo + layout ----------

// a comptime-only record, like a typeinfo
fn rec1(fields: std::vec<cfield>) -> cval {
    return cval::STRUCT(VOID, move fields);
}

// a typeinfo kind (a variant of no real enum)
fn kind_of(name: str, payload: cval?) -> cval {
    if (payload == null) {
        return cval::VARIANT(VOID, name, null);
    }
    return cval::VARIANT(VOID, name, some_c(copy payload.value));
}

// a usize? value; an OPT carries the optional type (usize?), not its payload's
attach fn opt_usize(this: checker&, v: u64?) -> cval {
    val t = this.t.opt_of(USIZE);
    if (v == null) {
        return cval::OPT(t, null);
    }
    return cval::OPT(t, some_c(cval::INT(@cast<i128>(v ?? 0), USIZE)));
}

fn types_c(ts: std::vec<u32>&) -> cval {
    var es: std::vec<cval> = {};
    for (t&) in ts.items() {
        put(&es, cval::TYPE(*t));
    }
    return cval::ARRAY(move es, TYPE);
}

fn cf(name: str, v: cval) -> cfield {
    return { name: name, v: move v };
}

fn tuple2(a: cval, b: cval) -> cval {
    var es: std::vec<cval> = {};
    put(&es, move a);
    put(&es, move b);
    return cval::TUPLE(move es);
}

// the @typeinfo record of t: its names, kind (with the kind's details), layout, generic args and so on
attach fn typeinfo(this: checker&, t: u32, span: span) -> compile_error!cval {
    val full = this.ty_name(t);
    val fs = full.as_str();
    var base_end = fs.len;
    for (i) in 0..fs.len {
        if (fs[i] == '<') {
            base_end = i;
            break;
        }
    }
    val base = fs[0..base_end];
    var cut: usize? = null;
    var i: usize = 0;
    while (i + 1 < base.len) {
        if (base[i] == ':' && base[i + 1] == ':') {
            cut = i;
        }
        i += 1;
    }
    var short = S(base);
    var module: std::string = {};
    if (cut) {
        short = S(base[(cut) + 2..base.len]);
        module = S(base[0..(cut)]);
    }
    var size: u64? = null;
    var align: u64? = null;
    if (t != VOID) {
        val lr = this.layout_opt(t, span);
        if (lr) {
            size = lr.size;
            align = lr.align;
        }
    }
    val u16t = int_id(int_ty::U16);
    var kind = cval::VOID;
    match (*this.t.get(t)) {
        .VOID => { kind = kind_of("VOID", null); },
        .NEVER => { kind = kind_of("NEVER", null); },
        .BOOL => { kind = kind_of("BOOL", null); },
        .TYPE => { kind = kind_of("TYPE", null); },
        .INT(k) => { kind = kind_of("INT", tuple2(cval::BOOL(k.signed()), cval::INT(@cast<i128>(k.bits()), u16t))); },
        .FLOAT(b) => { kind = kind_of("FLOAT", cval::INT(@cast<i128>(b), u16t)); },
        .REF(c) => { kind = kind_of("REFERENCE", cval::TYPE(c)); },
        .PTR(c) => { kind = kind_of("POINTER", cval::TYPE(c)); },
        .ARRAY(c, n) => { kind = kind_of("ARRAY", tuple2(cval::TYPE(c), cval::INT(@cast<i128>(n), USIZE))); },
        .SLICE(c) => { kind = kind_of("SLICE", cval::TYPE(c)); },
        .STR => { kind = kind_of("SLICE", cval::TYPE(U8)); },
        .OPT(c) => { kind = kind_of("OPTIONAL", cval::TYPE(c)); },
        .ERR_UNION(e, p) => { kind = kind_of("ERROR_UNION", tuple2(cval::TYPE(e), cval::TYPE(p))); },
        .RANGE(c) => { kind = kind_of("RANGE", cval::TYPE(c)); },
        .TUPLE(ts&, names) => { kind = kind_of("TUPLE", types_c(ts)); },
        .STRUCT(sid) => {
            val nf = (try this.struct_fields(sid, span)).len;
            var out: std::vec<cval> = {};
            var off: u64 = 0;
            for (k) in 0..nf {
                val f = *(try this.struct_fields(sid, span)).at(k);
                val l = try this.layout(f.ty, span);
                var a = l.align;
                if (a == 0) {
                    a = 1;
                }
                off = (off + a - 1) / a * a;
                var fields: std::vec<cfield> = {};
                put(&fields, cf("name", cval::STR(S(f.name))));
                put(&fields, cf("field_type", cval::TYPE(f.ty)));
                put(&fields, cf("offset", this.opt_usize(off)));
                put(&fields, cf("default_expr", cval::OPT(this.t.opt_of(STR), null)));
                put(&fields, cf("visibility", kind_of("PUBLIC", null)));
                put(&fields, cf("attributes", try this.field_attrs(sid, f.name)));
                put(&out, rec1(move fields));
                off += l.size;
            }
            kind = kind_of("STRUCT", tuple2(cval::ARRAY(move out, VOID), kind_of("C", null)));
        },
        .ENUM(e) => {
            val payloads = copy *(try this.enum_payloads(e, span));
            val names = copy this.ei(e).names;
            val values = copy this.ei(e).values;
            val tag = this.ei(e).tag;
            val is_error = this.ei(e).is_error;
            var vars: std::vec<cval> = {};
            for (k) in 0..names.len {
                var fields: std::vec<cfield> = {};
                put(&fields, cf("name", cval::STR(S(*names.at(k)))));
                put(&fields, cf("discriminant", cval::OPT(this.t.opt_of(I64), some_c(cval::INT(*values.at(k), I64)))));
                val pt = *payloads.at(k);
                if (pt) {
                    put(&fields, cf("payload", cval::OPT(this.t.opt_of(TYPE), some_c(cval::TYPE(pt)))));
                } else {
                    put(&fields, cf("payload", cval::OPT(this.t.opt_of(TYPE), null)));
                }
                put(&fields, cf("attributes", cval::ARRAY({}, VOID)));
                put(&vars, rec1(move fields));
            }
            if (is_error) {
                kind = kind_of("ERROR_SET", cval::ARRAY(move vars, VOID));
            } else {
                kind = kind_of("ENUM", tuple2(cval::TYPE(int_id(tag)), cval::ARRAY(move vars, VOID)));
            }
        },
        .FN_PTR(ps&, r, va) => { kind = this.fn_kind(ps, r); },
        .FN_VAL(ps&, r) => { kind = this.fn_kind(ps, r); },
        .CLOSURE(c) => {
            var ts: std::vec<u32> = {};
            for (x&) in this.ci(c).caps.items() {
                put(&ts, x.ty);
            }
            kind = kind_of("CLOSURE", types_c(&ts));
        },
        .TRAIT_UNION(u) => { kind = kind_of("TRAIT_UNION", tuple2(cval::STR(S(this.ui(u).name)), types_c(&this.ui(u).members))); },
        default => { kind = kind_of("UNKNOWN", null); },
    }
    var gargs: std::vec<cval> = {};
    match (*this.t.get(t)) {
        .STRUCT(s) => {
            for (g&) in this.si(s).args.items() {
                put(&gargs, this.gval_cval(g));
            }
        },
        .ENUM(e) => {
            for (g&) in this.ei(e).args.items() {
                put(&gargs, this.gval_cval(g));
            }
        },
        default => {},
    }
    val is_pod = !(try this.needs_drop(t));
    var r: std::vec<cfield> = {};
    put(&r, cf("id", cval::INT(@cast<i128>(t), int_id(int_ty::U128))));
    put(&r, cf("canonical_name", cval::STR(copy full)));
    put(&r, cf("short_name", cval::STR(move short)));
    put(&r, cf("module_path", cval::STR(move module)));
    put(&r, cf("kind", move kind));
    put(&r, cf("size", this.opt_usize(size)));
    put(&r, cf("align", this.opt_usize(align)));
    put(&r, cf("stride", this.opt_usize(size)));
    put(&r, cf("is_pod", cval::BOOL(is_pod)));
    put(&r, cf("is_comptime_only", cval::BOOL(t == TYPE)));
    put(&r, cf("generic_args", cval::ARRAY(move gargs, VOID)));
    put(&r, cf("visibility", kind_of("PUBLIC", null)));
    // a struct's or enum's library attributes
    var attributes = cval::TUPLE({});
    match (*this.t.get(t)) {
        .STRUCT(s) => { attributes = try this.user_attrs(&this.item_of(this.si(s).decl).attrs, this.si(s).env); },
        .ENUM(e) => { attributes = try this.user_attrs(&this.item_of(this.ei(e).decl).attrs, this.ei(e).env); },
        default => {},
    }
    put(&r, cf("attributes", move attributes));
    return rec1(move r);
}

// the value of x if it's known at compile time, else null (no error)
attach fn try_ct_eval(this: checker&, x: expr&, want: u32?) -> cval? {
    val v = this.ct_eval(x, want) catch |e| { return null; };
    return v;
}

// a comptime value as Volt writes it (what @expand and the editor show)
attach fn cval_text(this: checker&, v: cval&) -> std::string {
    match (*v) {
        .VOID => { return S("()"); },
        .NULL => { return S("null"); },
        .BOOL(b) => {
            if (b) {
                return S("true");
            }
            return S("false");
        },
        .INT(n, k) => { return num(n); },
        .FLOAT(f, k) => { return std::format("{}", f); },
        .STR(s) => { return fmt("\"{}\"", copy s); },
        .TYPE(t) => { return this.ty_name(t); },
        .TUPLE(vs) => { return fmt("({})", this.cvals_text(&vs)); },
        .ARRAY(vs, t) => { return fmt("{{ {} }}", this.cvals_text(&vs)); },
        .STRUCT(t, fs) => {
            var body: std::string = {};
            for (i) in 0..fs.len {
                if (i > 0) {
                    body.append(", ");
                }
                body.append(fs.at(i).name);
                body.append(": ");
                body.append(this.cval_text(&fs.at(i).v).as_str());
            }
            if (t == VOID) {
                return fmt("{{ {} }}", move body);
            }
            return fmt2("{} {{ {} }}", this.ty_name(t), move body);
        },
        .VARIANT(t, n, p) => {
            if (p != null) {
                return fmt2(".{}({})", S(n), this.cval_text(p.value));
            }
            return fmt(".{}", S(n));
        },
        .OPT(t, p) => {
            if (p != null) {
                return this.cval_text(p.value);
            }
            return S("null");
        },
    }
}

attach fn cvals_text(this: checker&, vs: std::vec<cval>&) -> std::string {
    var out: std::string = {};
    for (i) in 0..vs.len {
        if (i > 0) {
            out.append(", ");
        }
        out.append(this.cval_text(vs.at(i)).as_str());
    }
    return out;
}

// a fn instance as its signature (its name has its generic args): twice<i32>(v: i32) -> i32
attach fn inst_label(this: checker&, i: u32) -> std::string {
    var ps: std::string = {};
    val f = this.fi(i);
    for (k) in 0..f.params.len {
        if (k > 0) {
            ps.append(", ");
        }
        ps.append(f.params.at(k).name);
        ps.append(": ");
        ps.append(this.ty_name(f.params.at(k).ty).as_str());
    }
    return fmt3("{}({}) -> {}", S(f.name), move ps, this.ty_name(f.ret));
}

// a value spliced into a quote, as source text: a str's text (a name, or code), a type by its name, a
// number, a bool
attach fn splice_text(this: checker&, v: cval, span: span) -> compile_error!std::string {
    match (v) {
        .STR(s) => { return copy s; },
        .TYPE(t) => { return this.ty_name(t); },
        .INT(n, k) => { return num(n); },
        .BOOL(b) => {
            if (b) {
                return S("true");
            }
            return S("false");
        },
        .STRUCT(t, fs) => { return fail(span, fmt("can't splice a {} into code (it takes text, a type, a number or a bool)", this.ty_name(t))); },
        default => {},
    }
    return fails(span, "can't splice this value into code (it takes text, a type, a number or a bool)");
}

// a library's attribute: a struct (or comptime fn) named and called, or a comptime value's name;
// it's evaluated when @typeinfo reads it
fn check_user_attr(a: expr&) -> compile_error!void {
    match (a.kind) {
        .PATH(p) => { return; },
        .CALL(f, args) => {
            match (f.kind) {
                .PATH(p) => { return; },
                default => {},
            }
        },
        default => {},
    }
    return fails(a.span, "an attribute is a builtin (@inline) or a library's value (json::rename(\"id\"))");
}

// a library's attribute's value: a struct's name called like a function is that struct, its fields
// filled in order (the rest take their defaults); anything else is a comptime value
attach fn user_attr(this: checker&, e: expr&, env: u32) -> compile_error!cval {
    match (e.kind) {
        .CALL(callee, args&) => {
            match (callee.kind) {
                .PATH(p&) => {
                    val as_ty = this.keep_ty({ kind: type_kind::PATH(copy *p), span: callee.span });
                    val t = this.resolve_type(as_ty, env) catch |x| { return this.ct_eval_in(env, e, null); };
                    match (*this.t.get(t)) {
                        .STRUCT(sid) => {
                            val fields = copy *(try this.struct_fields(sid, e.span));
                            if (args.len > fields.len) {
                                return fail(e.span, fmt3("{} has {} field(s), given {} values", this.ty_name(t), unum(@cast<u64>(fields.len)), unum(@cast<u64>(args.len))));
                            }
                            var entries: std::vec<lit_entry> = {};
                            for (i) in 0..args.len {
                                put(&entries, { name: fields.at(i).name, value: copy *args.at(i) });
                            }
                            val lit: expr = { kind: expr_kind::LITERAL(move entries), span: e.span };
                            return this.ct_eval_in(env, &lit, t);
                        },
                        default => {},
                    }
                },
                default => {},
            }
        },
        default => {},
    }
    return this.ct_eval_in(env, e, null);
}

// the library attributes among attrs (the builtins mean something to the compiler, and aren't
// listed), as a tuple
attach fn user_attrs(this: checker&, attrs: std::vec<expr>&, env: u32) -> compile_error!cval {
    var out: std::vec<cval> = {};
    for (a&) in attrs.items() {
        match (a.kind) {
            .BUILTIN(n, g, x) => {},
            default => { put(&out, try this.user_attr(a, env)); },
        }
    }
    return cval::TUPLE(move out);
}

// struct sid's field name's library attributes
attach fn field_attrs(this: checker&, sid: u32, name: str) -> compile_error!cval {
    match (this.item_of(this.si(sid).decl).kind) {
        .STRUCT(sd&) => {
            for (f&) in sd.fields.items() {
                if (f.name == name) {
                    return this.user_attrs(&f.attrs, this.si(sid).env);
                }
            }
        },
        default => {},
    }
    return cval::TUPLE({});
}

// the FUNCTION kind of a fn pointer or fn value type
attach fn fn_kind(this: checker&, ps: std::vec<u32>&, r: u32) -> cval {
    var es: std::vec<cval> = {};
    put(&es, types_c(ps));
    put(&es, cval::TYPE(r));
    put(&es, cval::BOOL(false));
    put(&es, cval::BOOL(false));
    put(&es, cval::STR(S("C")));
    return kind_of("FUNCTION", cval::TUPLE(move es));
}

// layout, or none when the type has no compile-time layout
attach fn layout_opt(this: checker&, t: u32, span: span) -> lay? {
    val l = this.layout(t, span) catch |x| {
        return null;
    };
    return l;
}

// fields one after another, each at its alignment
attach fn layout_rec(this: checker&, ts: std::vec<u32>&, span: span) -> compile_error!lay {
    var off: u64 = 0;
    var al: u64 = 1;
    for (t&) in ts.items() {
        val l = try this.layout(*t, span);
        off = (off + l.align - 1) / l.align * l.align + l.size;
        if (l.align > al) {
            al = l.align;
        }
    }
    return { size: (off + al - 1) / al * al, align: al };
}

// size and alignment as the C compiler lays things out (x86_64 SysV)
// ponytail: one target's rules; add a target table when voltc cross-compiles
attach fn layout(this: checker&, t: u32, span: span) -> compile_error!lay {
    match (*this.t.get(t)) {
        .STRUCT(s) => {
            // only fields Volt could read were imported, so only C knows the real layout
            if (this.header_struct(s)) {
                return fail(span, fmt("C struct {} has no compile-time layout; @sizeof works on it at runtime", this.ty_name(t)));
            }
            var fs: std::vec<u32> = {};
            for (f&) in (try this.struct_fields(s, span)).items() {
                put(&fs, f.ty);
            }
            return this.layout_rec(&fs, span);
        },
        .VOID => { return { size: 0, align: 1 }; },
        .NEVER => { return { size: 0, align: 1 }; },
        .BOOL => { return { size: 1, align: 1 }; },
        .INT(k) => {
            val b = @cast<u64>(k.bits() / 8);
            return { size: b, align: b };
        },
        .FLOAT(b) => {
            val n = @cast<u64>(b / 8);
            return { size: n, align: n };
        },
        .REF(x) => { return { size: 8, align: 8 }; },
        .PTR(x) => { return { size: 8, align: 8 }; },
        .VOIDPTR => { return { size: 8, align: 8 }; },
        .CSTR => { return { size: 8, align: 8 }; },
        .NULL => { return { size: 8, align: 8 }; },
        .FN_PTR(ps, r, va) => { return { size: 8, align: 8 }; },
        .ANYERR => { return { size: 4, align: 4 }; }, // a uint32_t code
        .STR => { return { size: 16, align: 8 }; },
        .SLICE(x) => { return { size: 16, align: 8 }; },
        .FN_VAL(ps, r) => { return { size: 16, align: 8 }; },
        .OPT(i) => {
            if (this.t.is_niche(i)) {
                return { size: 8, align: 8 };
            }
            if (this.niche_field(i) != null) {
                return this.layout(i, span);
            }
            val xs = nodes2(i, BOOL);
            return this.layout_rec(&xs, span);
        },
        .ARRAY(e, n) => {
            val l = try this.layout(e, span);
            return { size: l.size * n, align: l.align };
        },
        .TUPLE(ts, names) => {
            val xs = copy ts;
            return this.layout_rec(&xs, span);
        },
        .RANGE(e) => {
            val xs = nodes2(e, e);
            return this.layout_rec(&xs, span);
        },
        .ENUM(e) => {
            val tag = int_id(this.ei(e).tag);
            if (!this.ei(e).has_payload) {
                return this.layout(tag, span);
            }
            var us: u64 = 0;
            var ua: u64 = 1;
            val ps = copy *(try this.enum_payloads(e, span));
            for (p&) in ps.items() {
                if (*p) {
                    val l = try this.layout(*p ?? 0, span);
                    if (l.size > us) {
                        us = l.size;
                    }
                    if (l.align > ua) {
                        ua = l.align;
                    }
                }
            }
            val tl = try this.layout(tag, span);
            val off = (tl.size + ua - 1) / ua * ua;
            var al = tl.align;
            if (ua > al) {
                al = ua;
            }
            val body = (us + ua - 1) / ua * ua;
            return { size: (off + body + al - 1) / al * al, align: al };
        },
        .ERR_UNION(e, p) => {
            val xs = nodes2(e, p);
            return this.layout_rec(&xs, span);
        },
        .TRAIT_UNION(u) => {
            var us: u64 = 0;
            var ua: u64 = 1;
            val ms = copy this.ui(u).members;
            for (m&) in ms.items() {
                val l = try this.layout(*m, span);
                if (l.size > us) {
                    us = l.size;
                }
                if (l.align > ua) {
                    ua = l.align;
                }
            }
            val off = (2 + ua - 1) / ua * ua;
            var al = ua;
            if (al < 2) {
                al = 2;
            }
            return { size: (off + us + al - 1) / al * al, align: al };
        },
        .CLOSURE(c) => {
            var ts: std::vec<u32> = {};
            for (x&) in this.ci(c).caps.items() {
                put(&ts, x.ty);
            }
            if (ts.len == 0) {
                return { size: 1, align: 1 };
            }
            return this.layout_rec(&ts, span);
        },
        default => { return fail(span, fmt("{} has no runtime size", this.ty_name(t))); },
    }
}

// an imported C struct: only C knows its layout
attach fn header_struct(this: checker&, sid: u32) -> bool {
    match (this.item_of(this.si(sid).decl).kind) {
        .STRUCT(d) => { return d.c_name != null; },
        default => { return false; },
    }
}

// a header struct with members the importer couldn't read (bitfields, unions): C knows its layout,
// Volt doesn't
attach fn partial_struct(this: checker&, sid: u32) -> bool {
    match (this.item_of(this.si(sid).decl).kind) {
        .STRUCT(d) => { return d.c_partial; },
        default => { return false; },
    }
}

// a header struct whose fields share bytes (an anonymous union member): field i's byte offset
attach fn overlay_offset(this: checker&, sid: u32, i: u32) -> u64? {
    match (this.item_of(this.si(sid).decl).kind) {
        .STRUCT(d&) => {
            if (d.c_offsets) {
                return *d.c_offsets.at(@cast<usize>(i));
            }
        },
        default => {},
    }
    return null;
}

// ...and its C size and alignment (size 0: it isn't one)
attach fn overlay_size(this: checker&, sid: u32) -> (u64, u64) {
    match (this.item_of(this.si(sid).decl).kind) {
        .STRUCT(d&) => { return (d.c_size, d.c_align); },
        default => { return (0, 0); },
    }
}

// a C union: its fields share offset 0
attach fn union_struct(this: checker&, sid: u32) -> bool {
    match (this.item_of(this.si(sid).decl).kind) {
        .STRUCT(d) => { return d.c_union; },
        default => { return false; },
    }
}

// ---------- comptime match / for inside a runtime fn ----------

// comptime match inside a runtime fn: pick the arm now, check only its body
attach fn ct_match(this: checker&, scrut: expr&, arms: std::vec<arm>&, want: u32?, span: span) -> compile_error!tval {
    val v = try this.ct_eval(scrut, null);
    for (a&) in arms.items() {
        var fr: ct_frame = { scopes: {}, env: this.cx.env };
        put(&fr.scopes, {});
        put(&this.ct, move fr);
        val hit = this.ct_hit(a, &v);
        var fr2 = this.ct.pop() ?? return fails(span, "");
        var binds = fr2.scopes.pop() ?? {};
        val h = hit catch |e| {
            if (this.take_flow() != null) {
                return fails(a.span, "can't leave a comptime match pattern");
            }
            return copy e;
        };
        if (h) {
            if (this.opts.expand || this.opts.lsp) {
                this.expanded(a.pat.span, fmt("comptime match: {}, this arm", this.cval_text(&v)));
            }
            var s: scope = {};
            s.consts = move binds;
            put(&this.cx.scopes, move s);
            val r = this.expr(&a.body, want);
            this.cx.scopes.pop();
            return r;
        }
    }
    return fails(span, "no comptime match arm matched");
}

// whether comptime match arm a picks v (pattern, then guard)
attach fn ct_hit(this: checker&, a: arm&, v: cval&) -> compile_error!bool {
    if (!(try this.ct_pat(&a.pat, v))) {
        return false;
    }
    if (a.guard) {
        return this.ct_bool(&a.guard);
    }
    return true;
}

// comptime for: unrolled at compile time. Over a compile-time list, the loop variable is a
// constant; over a runtime tuple (a pack like args), each copy sees one element with its own type.
attach fn ct_for_unroll(this: checker&, f: for_loop&, span: span) -> compile_error!tval {
    val li = this.push_loop(f.label, false, false, null);
    val r = this.ct_unroll_body(f, li);
    val lc = this.cx.loops.pop() ?? return fails(span, "");
    var stmts = try r;
    put(&stmts, this.ir.label_at(lc.brk));
    return vnew(VOID, this.ir.block(move stmts));
}

// evaluates the iterable, then emits one copy of the body per element; returns the statements (the
// caller adds the break label)
attach fn ct_unroll_body(this: checker&, f: for_loop&, li: usize) -> compile_error!std::vec<u32> {
    val name = f.bindings.at(0).name;
    var code: std::vec<u32> = {};
    var runtime: tval? = null;
    var is_range = false;
    match (f.iter.kind) {
        .RANGE(lo, hi, incl) => { is_range = true; },
        default => {},
    }
    if (!is_range && !this.is_ct_expr(&f.iter)) {
        runtime = try this.expr(&f.iter, null);
    }
    var consts: std::vec<cval> = {};
    var elems: std::vec<u32> = {};  // element types of a runtime tuple
    var base: u32 = 0;
    if (runtime) {
        val rv = runtime;
        match (*this.t.get(rv.ty)) {
            .TUPLE(ts, names) => {
                elems = copy ts;
                // the tuple is read once per element, so keep it in a temp
                val tt = this.tmp_local("tu", rv.ty);
                put(&code, this.ir.decl(tt.id, rv.c));
                base = tt.c;
            },
            .VOID => {}, // an empty pack
            default => { return fails(f.iter.span, "comptime for loops over a tuple, pack, range or compile-time list"); },
        }
    } else {
        match (f.iter.kind) {
            .RANGE(lo, hi, incl) => {
                if (lo == null || hi == null) {
                    return fails(f.iter.span, "comptime for needs a list it can see at compile time");
                }
                val a = try this.const_int(lo.value, this.cx.env);
                val b = try this.const_int(hi.value, this.cx.env);
                var end = b;
                if (incl) {
                    end = b + 1;
                }
                var i = a;
                while (i < end) {
                    put(&consts, cval::INT(i, VOID));
                    i += 1;
                }
            },
            default => {
                val v = try this.ct_eval(&f.iter, null);
                match (v) {
                    .ARRAY(es, t) => { consts = copy es; },
                    .TUPLE(es) => { consts = copy es; },
                    default => { return fails(f.iter.span, "comptime for needs a list it can see at compile time"); },
                }
            },
        }
    }
    var n = consts.len;
    if (runtime != null) {
        n = elems.len;
    }
    if (this.opts.expand || this.opts.lsp) {
        if (runtime != null) {
            this.expanded(f.iter.span, fmt2("comptime for: {} copies, {} one per element", num(@cast<i128>(n)), S(name)));
        } else {
            this.expanded(f.iter.span, fmt3("comptime for: {} copies, {} = {}", num(@cast<i128>(n)), S(name), this.cvals_text(&consts)));
        }
    }
    for (i) in 0..n {
        val cont = this.ir.label();
        this.cx.loops.at(li).cont = cont;
        var s: scope = {};
        var body: std::vec<u32> = {};
        if (runtime != null) {
            val t = *elems.at(i);
            this.cx.next_id += 1;
            var ln = S(name);
            ln.push('_');
            ln.append_uint(@cast<u64>(this.cx.next_id));
            val l = this.new_ir_local(this.intern(move ln), t);
            put(&body, this.ir.decl(l.id, this.ir.field(base, @cast<u32>(i), t)));
            s.vars.put(name, { c: l.c, ty: t, mutable: false });
        } else {
            s.consts.put(name, { value: copy *consts.at(i), mutable: false });
        }
        if (f.bindings.len > 1) {
            s.consts.put(f.bindings.at(1).name, { value: cval::INT(@cast<i128>(i), USIZE), mutable: false });
        }
        put(&this.cx.scopes, move s);
        val r = this.block_code(&f.body);
        this.cx.scopes.pop();
        put(&body, (try r).c);
        put(&body, this.ir.label_at(cont));
        put(&code, this.ir.block(move body));
    }
    return code;
}

// ---------- attributes ----------

// an attribute's name and argument count
struct attr_def {
    name: str;
    args: usize;
}

// the attributes that exist (enum attribute in the spec); @intrinsic is for packages (a std, or
// any library) to bind compiler-provided functions like println
fn attr_defs() -> std::vec<attr_def> {
    var v: std::vec<attr_def> = {};
    put(&v, { name: "inline", args: 0 });
    put(&v, { name: "noinline", args: 0 });
    put(&v, { name: "opt", args: 1 });
    put(&v, { name: "section", args: 1 });
    put(&v, { name: "align", args: 1 });
    put(&v, { name: "deprecated", args: 1 });
    put(&v, { name: "owns", args: 1 });
    put(&v, { name: "cpp_type", args: 1 }); // a struct is this C++ class (use cpp writes it)
    put(&v, { name: "export_text", args: 1 }); // a struct is text, as this method gives it, to other languages (voltc bindings)
    put(&v, { name: "thread_local", args: 0 }); // a global var each thread has its own of
    put(&v, { name: "cfg", args: 2 }); // the item is only in builds where this @cfg holds (1 or 2 arguments)
    put(&v, { name: "optional", args: 0 }); // a trait fn an attach block may leave out
    put(&v, { name: "closed", args: 0 }); // a trait whose attach blocks hold its fns only
    put(&v, { name: "attach_as", args: 1 }); // a struct attach blocks name for this trait (a C++ class's virtuals)
    put(&v, { name: "derive", args: 1 }); // attach these traits (std::derive's when not in scope) to the struct or enum
    return v;
}

// an attribute's string argument: @owns("ptr") -> ptr
fn attr_str(a: expr&) -> str? {
    match (a.kind) {
        .BUILTIN(n, g, args) => {
            if (args == null || args.value.len == 0) {
                return null;
            }
            match (*args.value.at(0)) {
                .EXPR(e) => {
                    match (e.kind) {
                        .STR(s) => { return s.as_str(); },
                        default => { return null; },
                    }
                },
                default => { return null; },
            }
        },
        default => { return null; },
    }
}

// @cfg(KEY) / @cfg(KEY, VALUE), as a builtin or an item's attribute: was --cfg KEY[=VALUE] given for
// the package the code at span is in, or is it one of the target's keys (os, arch, pointer_bits)?
attach fn cfg_on(this: checker&, parts: std::vec<std::string>&, span: span) -> compile_error!bool {
    if (parts.len == 0 || parts.len > 2) {
        return fails(span, "@cfg(KEY) or @cfg(KEY, VALUE)");
    }
    val key_only = parts.len == 1;
    var want = copy *parts.at(0);
    if (!key_only) {
        want.push('=');
        want.append(parts.at(1).as_str());
    }
    // @cfg("release"): an optimized build (--release), for code that trades checks for speed
    if (key_only && want.as_str() == "release") {
        return this.opts.release;
    }
    // hosted and unix follow os alone (as the bootstrap compiler has them)
    // @cfg("hosted"): there's an OS (any target but os=none, bare metal), for std's OS parts
    if (key_only && want.as_str() == "hosted") {
        return (this.cfg_given("os") ?? "") != "none";
    }
    // @cfg("unix"): a POSIX system (Linux, macOS, FreeBSD), for std's code that Windows hasn't
    if (key_only && want.as_str() == "unix") {
        val target_os = this.cfg_given("os") ?? std::process::os();
        return target_os == "linux" || target_os == "macos" || target_os == "freebsd";
    }
    val pkg = this.pkg_of_file(span.file);
    for (c&) in this.opts.cfg.items() {
        if (!same_pkg(c.pkg, pkg) || is_target_key(c.set)) {
            continue;
        }
        // a key alone matches KEY and KEY=anything
        if (cfg_matches(c.set, want.as_str(), key_only)) {
            return true;
        }
    }
    // the target's keys, for every package: the host's values (this voltc's runtime names them),
    // unless --cfg gives one for any package, which replaces it (checking another platform's code)
    var host_bits = S("");
    host_bits.append_uint(@cast<u64>(@sizeof(usize) * 8));
    var os = S("os=");
    os.append(this.cfg_given("os") ?? std::process::os());
    var arch = S("arch=");
    arch.append(this.cfg_given("arch") ?? std::process::arch());
    var bits = S("pointer_bits=");
    bits.append(this.cfg_given("pointer_bits") ?? host_bits.as_str());
    val on_target = cfg_matches(os.as_str(), want.as_str(), key_only) || cfg_matches(arch.as_str(), want.as_str(), key_only) || cfg_matches(bits.as_str(), want.as_str(), key_only);
    return on_target;
}

// an item's @cfg attributes all hold (an item without one is always in)
attach fn item_cfg_on(this: checker&, attrs: std::vec<expr>&) -> compile_error!bool {
    for (a&) in attrs.items() {
        match (a.kind) {
            .BUILTIN(n, g, args) => {
                if (n != "cfg" || args == null) {
                    continue;
                }
                var parts: std::vec<std::string> = {};
                for (x&) in args.value.items() {
                    var ok = false;
                    match (*x) {
                        .EXPR(e) => {
                            match (e.kind) {
                                .STR(t) => {
                                    put(&parts, S(t.as_str()));
                                    ok = true;
                                },
                                default => {},
                            }
                        },
                        default => {},
                    }
                    if (!ok) {
                        return fails(a.span, "@cfg takes strings: @cfg(\"os\", \"none\")");
                    }
                }
                if (!(try this.cfg_on(&parts, a.span))) {
                    return false;
                }
            },
            default => {},
        }
    }
    return true;
}

// rejects unknown attributes and wrong argument counts; @intrinsic is allowed only in package files
attach fn check_attr(this: checker&, a: expr&, file: u32) -> compile_error!void {
    var name: str = "";
    var n_args: usize = 0;
    match (a.kind) {
        .BUILTIN(n, g, args) => {
            name = n;
            if (args) {
                n_args = args.len;
            }
        },
        default => { return check_user_attr(a); },
    }
    if (name == "cfg") {
        if (n_args == 1 || n_args == 2) {
            return;
        }
        return fails(a.span, "@cfg takes 1 or 2 arguments: @cfg(\"os\", \"none\")");
    }
    if (name == "derive") {
        if (n_args >= 1) {
            return;
        }
        return fails(a.span, "@derive names the traits to attach: @derive(eq, hash)");
    }
    if (name == "intrinsic" || name == "runtime") {
        for (pf&) in this.opts.pkg_files.items() {
            if (pf.file == file) {
                return;
            }
        }
    }
    val defs = attr_defs();
    for (d&) in defs.items() {
        if (d.name == name) {
            if (d.args == n_args) {
                return;
            }
            return fail(a.span, fmt2("@{} takes {} argument(s)", S(name), unum(@cast<u64>(d.args))));
        }
    }
    var known: std::string = {};
    for (i) in 0..defs.len {
        if (i > 0) {
            known.append(", ");
        }
        known.push('@');
        known.append(defs.at(i).name);
    }
    return fail(a.span, fmt2("unknown attribute @{} (there are: {})", S(name), move known));
}

// an attribute's argument as text: @opt(2) -> "2", @section("x") -> "x"
attach fn attr_arg(this: checker&, a: expr&) -> str? {
    match (a.kind) {
        .BUILTIN(n, g, args) => {
            if (args == null || args.value.len == 0) {
                return null;
            }
            match (*args.value.at(0)) {
                .EXPR(e) => {
                    match (e.kind) {
                        .INT(v) => {
                            var s: std::string = {};
                            s.append_uint(@cast<u64>(v));
                            return this.intern(move s);
                        },
                        .STR(s) => { return this.intern(copy s); },
                        default => { return null; },
                    }
                },
                default => { return null; },
            }
        },
        default => { return null; },
    }
}

// a function's attributes, for the backends
attach fn fn_attrs_of(this: checker&, attrs: std::vec<expr>&) -> fn_attrs {
    var r: fn_attrs = {};
    for (a&) in attrs.items() {
        match (a.kind) {
            .BUILTIN(n, g, args) => {
                val arg = this.attr_arg(a);
                if (n == "inline") {
                    r.is_inline = true;
                } else if (n == "noinline") {
                    r.noinline = true;
                } else if (n == "opt") {
                    r.opt = arg ?? "";
                } else if (n == "section") {
                    r.section = arg ?? "";
                } else if (n == "align") {
                    r.align = arg ?? "";
                } else if (n == "deprecated") {
                    r.deprecated = true;
                }
            },
            default => {},
        }
    }
    return r;
}

// print a deprecation warning the first time a deprecated function is used
attach fn warn_deprecated(this: checker&, idx: u32, span: span) -> void {
    val decl = this.fi(idx).decl;
    var msg: str? = null;
    for (a&) in this.item_of(decl).attrs.items() {
        match (a.kind) {
            .BUILTIN(n, g, args) => {
                if (n == "deprecated") {
                    msg = this.attr_arg(a) ?? "";
                }
            },
            default => {},
        }
    }
    if (msg == null) {
        return;
    }
    if (this.warned.add(decl)) {
        var d: diag = { span: span, msg: fmt2("'{}' is deprecated: {}", S(this.fi(idx).name), S(msg ?? "")), warning: true };
        put(&d.labels, { span: this.item_of(decl).span, msg: S("declared here") });
        put(&this.warnings, move d);
    }
}

// whether attribute a is @name
fn attr_named(a: expr&, name: str) -> bool {
    match (a.kind) {
        .BUILTIN(n, g, args) => { return n == name; },
        default => { return false; },
    }
}
