// Templates: generic params, inference, overload resolution for every call form (f(),
// Type::f(), x.f()), trait bounds, and traits used as types (tagged unions). A port of
// bootstrap/check/generics.rs.
use std::mem;

// a generic parameter: the item's own, or one made from a comptime parameter
struct gparam {
    name: str;
    bounds: std::vec<ty*> = {};
    pack: bool = false;
    fallback: garg* = null;
    span: span;
}

// the kind of a generic param: a type, a type pack (T...), or a value of this type (<N: i32>)
enum pkind {
    TYPE,
    PACK,
    CONST: u32,
}

// how a method call passes its receiver to `this`: as it is, by taking its address (REF), or
// through the reference it is (DEREF)
enum adj {
    NONE,
    REF,
    DEREF,
}

// a fn's receiver with its type pattern: none (a plain fn), `static this` (called as Type::f()), or
// a value (called as x.f())
enum recv {
    NONE,
    STATIC: ty*,
    VAL: ty*,
}

// what Type::name refers to: a member of a known type, or a variant of a generic enum written
// without its args (the instance is inferred: infer_enum)
enum member {
    OF: (u32, str),
    GENERIC_ENUM: (u32, str),
}

// a candidate's bound generics, or why it doesn't fit
enum bound {
    OK: (std::vec<gval>, adj),
    NO: std::string,
}

// a made-up type expression that lives as long as the checker (keep_garg: the same for a generic arg)
attach fn keep_ty(this: checker&, t: ty) -> ty& {
    put(&this.owned_tys, bx(move t));
    return *this.owned_tys.at(this.owned_tys.len - 1);
}

attach fn keep_garg(this: checker&, g: garg) -> garg& {
    put(&this.owned_gargs, bx(move g));
    return *this.owned_gargs.at(this.owned_gargs.len - 1);
}

attach fn new_gparams(this: checker&, v: std::vec<gparam>) -> u32 {
    put(&this.gparam_lists, bx(move v));
    return @cast<u32>(this.gparam_lists.len - 1);
}

fn gparam_of(g: generic_param&) -> gparam {
    var p: gparam = { name: g.name, pack: g.pack, span: g.span };
    for (b&) in g.bounds.items() {
        put(&p.bounds, b);
    }
    if (g.fallback) {
        p.fallback = &g.fallback;
    }
    return move p;
}

// an item's own generic params
attach fn gparams_of(this: checker&, d: u32) -> std::vec<gparam>& {
    val have = this.item_gparams.get(d);
    if (have) {
        return *this.gparam_lists.at(@cast<usize>(*have));
    }
    var out: std::vec<gparam> = {};
    for (g&) in this.item_of(d).generics.items() {
        put(&out, gparam_of(g));
    }
    val id = this.new_gparams(move out);
    this.item_gparams.put(d, id);
    return *this.gparam_lists.at(@cast<usize>(id));
}

// generic params of a fn: its attach block's, its own, then its comptime params (a comptime param
// is a value parameter of the instance, like <N: i32>)
attach fn fn_generics(this: checker&, d: u32) -> std::vec<gparam>& {
    val have = this.fn_gparams.get(d);
    if (have) {
        return *this.gparam_lists.at(@cast<usize>(*have));
    }
    var out: std::vec<gparam> = {};
    val parent = this.dl(d).parent;
    if (parent) {
        match (this.item_of(parent).kind) {
            .ATTACH(a, b, c) => {
                for (g&) in this.item_of(parent).generics.items() {
                    put(&out, gparam_of(g));
                }
            },
            default => {},
        }
    }
    for (g&) in this.item_of(d).generics.items() {
        put(&out, gparam_of(g));
    }
    val f = this.fn_decl_of(d);
    if (f) {
        for (p&) in f.params.items() {
            if (!p.is_comptime) {
                continue;
            }
            var gp: gparam = { name: p.name, span: p.span };
            if (p.ty) {
                put(&gp.bounds, &p.ty);
            }
            if (p.fallback) {
                gp.fallback = this.keep_garg(garg::EXPR(copy p.fallback));
            }
            put(&out, move gp);
        }
    }
    val id = this.new_gparams(move out);
    this.fn_gparams.put(d, id);
    return *this.gparam_lists.at(@cast<usize>(id));
}

fn gparam_index(gps: std::vec<gparam>&, name: str) -> usize? {
    for (i) in 0..gps.len {
        if (gps.at(i).name == name) {
            return i;
        }
    }
    return null;
}

fn is_type_bound(t: ty&) -> bool {
    match (t.kind) {
        .PATH(p) => { return p.is_single() && p.segs.at(0).name == "type"; },
        default => { return false; },
    }
}

// bound_trait's answer: the trait's decl and the generic args the bound gives it
struct trait_ref {
    decl: u32;
    args: std::vec<garg>*; // null: none given
}

// the trait a bound names, with its generic args
attach fn bound_trait(this: checker&, t: ty&, ns: u32) -> trait_ref? {
    match (t.kind) {
        .PATH(p&) => {
            var f: found? = null;
            if (p.segs.len == 1) {
                f = this.lookup(ns, p.segs.at(0).name);
            } else {
                f = this.lookup_path_ns(ns, p);
            }
            match (f ?? return null) {
                .DECLS(l) => {
                    for (d&) in this.list(l).items() {
                        match (this.item_of(*d).kind) {
                            .TRAIT(n, fs) => {
                                var args: std::vec<garg>* = null;
                                val last = p.segs.at(p.segs.len - 1);
                                if (last.args) {
                                    args = &last.args;
                                }
                                if (this.opts.lsp) {
                                    this.lsp_decl_use(*d, last.name, p.span, this.lsp_type_label(*d, last.name));
                                }
                                return { decl: *d, args: args };
                            },
                            default => {},
                        }
                    }
                    return null;
                },
                default => { return null; },
            }
        },
        default => { return null; },
    }
}

// a pack, a type (every bound is `type` or a trait), or else a value of its one bound's type
attach fn param_kind(this: checker&, gp: gparam&, e: u32) -> compile_error!pkind {
    if (gp.pack) {
        return pkind::PACK;
    }
    var all_types = true;
    for (b&) in gp.bounds.items() {
        val bt = *b ?? continue;
        if (!(is_type_bound(bt) || this.bound_trait(bt, this.env_at(e).ns) != null)) {
            all_types = false;
        }
    }
    if (all_types) {
        return pkind::TYPE;
    }
    if (gp.bounds.len != 1) {
        return fails(gp.span, "a value parameter has exactly one type: <N: i32>");
    }
    val b0 = *gp.bounds.at(0) ?? return fails(gp.span, "a value parameter has exactly one type: <N: i32>");
    return pkind::CONST(try this.resolve_type(b0, e));
}

// a generic arg read as a type (a bare name parses as an expression)
attach fn garg_type_env(this: checker&, g: garg&, e: u32) -> compile_error!u32 {
    match (*g) {
        .TYPE(t&) => { return this.resolve_type(t, e); },
        .EXPR(x) => {
            match (x.kind) {
                .PATH(p&) => { return this.resolve_type_path(p, e); },
                default => { return fails(x.span, "expected a type"); },
            }
        },
    }
}

// a generic/builtin argument read as a value: names, calls and indexing (a[i]) parse as types first
attach fn garg_value(this: checker&, g: garg&) -> compile_error!(expr&) {
    match (*g) {
        .EXPR(x&) => { return x; },
        .TYPE(t&) => { return this.type_as_value(t); },
    }
}

// the expression a type-shaped arg spells: a name, a[i] or a[..] (which parse as array and slice types)
attach fn type_as_value(this: checker&, t: ty&) -> compile_error!(expr&) {
    match (t.kind) {
        .PATH(p) => { return this.keep_expr({ kind: expr_kind::PATH(copy p), span: t.span }); },
        .EXPR(x) => {
            val r: expr& = x;
            return r;
        },
        .ARRAY(elem, len) => {
            if (len != null) {
                val base = try this.type_as_value(elem);
                return this.keep_expr({ kind: expr_kind::INDEX(bx(copy *base), bx(copy *len.value)), span: t.span });
            }
        },
        .SLICE(elem) => {
            val base = try this.type_as_value(elem);
            val all: expr = { kind: expr_kind::RANGE(null, null, false), span: t.span };
            return this.keep_expr({ kind: expr_kind::INDEX(bx(copy *base), bx(move all)), span: t.span });
        },
        default => {},
    }
    return fails(t.span, "expected a value, found a type");
}

attach fn garg_span(this: checker&, g: garg&) -> span {
    match (*g) {
        .EXPR(x) => { return x.span; },
        .TYPE(t) => { return t.span; },
    }
}

// a generic arg's value for a param of this kind; value args are evaluated at compile time in env e
attach fn garg_gval(this: checker&, g: garg&, kind: pkind, e: u32) -> compile_error!gval {
    match (kind) {
        .TYPE => { return gval::TY(try this.garg_type_env(g, e)); },
        .CONST(t) => {
            val x = try this.garg_value(g);
            if (t == STR || t == CSTR) {
                val v = try this.ct_eval_in(e, x, t);
                match (v) {
                    .STR(s) => { return gval::STR(this.intern(copy s)); },
                    default => { return fails(x.span, "expected a string known at compile time"); },
                }
            }
            if (t == BOOL) {
                val v = try this.ct_eval_in(e, x, t);
                match (v) {
                    .BOOL(b) => {
                        if (b) {
                            return gval::INT(1);
                        }
                        return gval::INT(0);
                    },
                    default => { return fails(x.span, "expected a bool known at compile time"); },
                }
            }
            return gval::INT(try this.const_int(x, e));
        },
        .PACK => { return fails(this.garg_span(g), "pass pack members as ordinary arguments"); },
    }
}

// an env with the params bound so far (unbound ones are left out)
attach fn partial_env(this: checker&, ns: u32, gps: std::vec<gparam>&, binds: std::vec<gval?>&) -> u32 {
    var e: env = { ns: ns };
    for (i) in 0..gps.len {
        val b = *binds.at(i);
        if (b) {
            put(&e.generics, { name: gps.at(i).name, g: b});
        }
    }
    return this.new_env(move e);
}

// the type pat denotes with these bindings, or null if it names an unbound param or doesn't resolve
attach fn resolve_partial(this: checker&, pat: ty&, gps: std::vec<gparam>&, binds: std::vec<gval?>&, ns: u32) -> u32? {
    val e = this.partial_env(ns, gps, binds);
    val t = this.resolve_type(pat, e) catch |x| { return null; };
    return t;
}

fn none_binds(n: usize) -> std::vec<gval?> {
    var v: std::vec<gval?> = {};
    for (i) in 0..n {
        put(&v, null);
    }
    return move v;
}

// generic args for a generic type: given ones, then defaults
attach fn gargs_for(this: checker&, d: u32, given: std::vec<garg>&, caller: u32, span: span) -> compile_error!std::vec<gval> {
    val gps = this.gparams_of(d);
    val ns = this.dl(d).ns;
    if (given.len > gps.len) {
        return fail(span, fmt("too many generic arguments (expected {})", unum(@cast<u64>(gps.len))));
    }
    var binds = none_binds(gps.len);
    for (i) in 0..gps.len {
        val gp = gps.at(i);
        val e = this.partial_env(ns, gps, &binds);
        val kind = try this.param_kind(gp, e);
        if (i < given.len) {
            *binds.at(i) = try this.garg_gval(given.at(i), kind, caller);
        } else if (gp.fallback) {
            *binds.at(i) = try this.garg_gval(gp.fallback, kind, e);
        } else {
            return fail(span, fmt("missing generic argument '{}'", S(gp.name)));
        }
    }
    val out = unwrap_binds(&binds);
    val bad = try this.check_bounds(gps, &out, ns);
    if (bad) {
        return fail(span, copy bad);
    }
    return move out;
}

// ---------- inference ----------

// the struct/enum decl a type pattern path names (its primary, unspecialized decl)
attach fn pattern_family(this: checker&, p: path&, ns: u32) -> u32? {
    var f: found? = null;
    if (p.segs.len == 1) {
        f = this.lookup(ns, p.segs.at(0).name);
    } else {
        f = this.lookup_path_ns(ns, p);
    }
    match (f ?? return null) {
        .DECLS(l) => {
            for (d&) in this.list(l).items() {
                match (this.item_of(*d).kind) {
                    .STRUCT(s) => {
                        if (s.spec == null) {
                            return *d;
                        }
                    },
                    .ENUM(x) => { return *d; },
                    default => {},
                }
            }
            return null;
        },
        default => { return null; },
    }
}

// the name a generic arg is, when it's a single name
fn garg_name(g: garg&) -> str? {
    match (*g) {
        .TYPE(t) => {
            match (t.kind) {
                .PATH(p) => {
                    if (p.is_single()) {
                        return p.segs.at(0).name;
                    }
                },
                default => {},
            }
        },
        .EXPR(x) => {
            match (x.kind) {
                .PATH(p) => {
                    if (p.is_single()) {
                        return p.segs.at(0).name;
                    }
                },
                default => {},
            }
        },
    }
    return null;
}

// bind generic params (by name) that appear in pat from the actual type
attach fn infer(this: checker&, pat: ty&, actual: u32, gps: std::vec<gparam>&, binds: std::vec<gval?>&, ns: u32) -> void {
    val at = this.t.get(actual);
    match (pat.kind) {
        .PATH(p&) => {
            if (p.is_single()) {
                val i = gparam_index(gps, p.segs.at(0).name);
                if (i) {
                    val j = i;
                    if (*binds.at(j) == null) {
                        *binds.at(j) = gval::TY(actual);
                    }
                    return;
                }
            }
            // a generic struct/enum pattern (vec<T>) against an instance of that family: match the args
            val last = p.segs.at(p.segs.len - 1);
            if (last.args == null) {
                return;
            }
            var family: u32 = 0;
            var args: std::vec<gval>* = null;
            match (*at) {
                .STRUCT(s) => {
                    family = this.si(s).family;
                    args = &this.si(s).args;
                },
                .ENUM(e) => {
                    family = this.ei(e).family;
                    args = &this.ei(e).args;
                },
                default => { return; },
            }
            val fam = this.pattern_family(p, ns);
            if (fam == null || (fam ?? 0) != family) {
                return;
            }
            val pas = &last.args.value;
            val aa = args ?? return;
            var k: usize = 0;
            while (k < pas.len && k < aa.len) {
                val pa = pas.at(k);
                match (*aa.at(k)) {
                    .INT(v) => {
                        val n = garg_name(pa);
                        if (n) {
                            val j = gparam_index(gps, n);
                            if (j) {
                                if (*binds.at(j) == null) {
                                    *binds.at(j) = gval::INT(v);
                                }
                            }
                        }
                    },
                    .TY(t2) => {
                        match (*pa) {
                            .TYPE(t&) => { this.infer(t, t2, gps, binds, ns); },
                            .EXPR(x) => {
                                match (x.kind) {
                                    .PATH(pp) => {
                                        val synth = this.keep_ty({ kind: type_kind::PATH(copy pp), span: x.span });
                                        this.infer(synth, t2, gps, binds, ns);
                                    },
                                    default => {},
                                }
                            },
                        }
                    },
                    default => {},
                }
                k += 1;
            }
        },
        .REF(i) => {
            match (*at) {
                .REF(a) => { this.infer(i, a, gps, binds, ns); },
                default => {},
            }
        },
        // a T& converts to a T*, so a pointer pattern sees through references too
        .PTR(i) => {
            match (*at) {
                .PTR(a) => { this.infer(i, a, gps, binds, ns); },
                .REF(a) => { this.infer(i, a, gps, binds, ns); },
                default => {},
            }
        },
        .OPTIONAL(i) => {
            match (*at) {
                .OPT(a) => { this.infer(i, a, gps, binds, ns); },
                default => { this.infer(i, actual, gps, binds, ns); },
            }
        },
        .ARRAY(i, n) => {
            match (*at) {
                .ARRAY(a, len) => {
                    this.infer(i, a, gps, binds, ns);
                    if (n) {
                        match (n.kind) {
                            .PATH(np) => {
                                if (np.is_single()) {
                                    val j = gparam_index(gps, np.segs.at(0).name);
                                    if (j) {
                                        if (*binds.at(j) == null) {
                                            *binds.at(j) = gval::INT(@cast<i128>(len));
                                        }
                                    }
                                }
                            },
                            default => {},
                        }
                    }
                },
                default => {},
            }
        },
        .SLICE(i) => {
            match (*at) {
                .SLICE(a) => { this.infer(i, a, gps, binds, ns); },
                .ARRAY(a, n) => { this.infer(i, a, gps, binds, ns); },
                default => {},
            }
        },
        .TUPLE(ps) => {
            match (*at) {
                .TUPLE(ts, names) => {
                    if (ps.len == ts.len) {
                        for (k) in 0..ps.len {
                            this.infer(&ps.at(k).ty, *ts.at(k), gps, binds, ns);
                        }
                    }
                },
                default => {},
            }
        },
        .ERROR_UNION(e, i) => {
            match (*at) {
                .ERR_UNION(ae, a) => {
                    if (e) {
                        this.infer(e, ae, gps, binds, ns);
                    }
                    this.infer(i, a, gps, binds, ns);
                },
                default => {},
            }
        },
        .FN(f) => {
            var aps: std::vec<u32>* = null;
            var ar: u32 = 0;
            match (*at) {
                .FN_PTR(ps&, r, va) => {
                    aps = ps;
                    ar = r;
                },
                .FN_VAL(ps&, r) => {
                    aps = ps;
                    ar = r;
                },
                default => {},
            }
            val ps = aps ?? return;
            if (ps.len != f.params.len) {
                return;
            }
            for (k) in 0..ps.len {
                this.infer(f.params.at(k), *ps.at(k), gps, binds, ns);
            }
            this.infer(f.ret, ar, gps, binds, ns);
        },
        default => {},
    }
}

// ---------- candidates ----------

// a fn's receiver: `this`'s declared type, else its attach block's target (T& for a non-static
// this, made once per method: recv_refs)
attach fn recv_of(this: checker&, d: u32) -> recv {
    val f = this.fn_decl_of(d) ?? return recv::NONE;
    if (f.params.len == 0 || f.params.at(0).name != "this") {
        return recv::NONE;
    }
    val p = f.params.at(0);
    var target: ty* = null;
    val parent = this.dl(d).parent;
    if (parent) {
        match (this.item_of(parent).kind) {
            .ATTACH(tr, tg&, fs) => { target = tg; },
            default => {},
        }
    }
    var pat: ty* = null;
    if (p.ty) {
        pat = &p.ty;
    } else if (target) {
        val tg = target;
        if (p.is_static) {
            pat = tg;
        } else {
            val have = this.recv_refs.get(d);
            if (have) {
                pat = *have;
            } else {
                val r = this.keep_ty({ kind: type_kind::REF(bx(copy *tg)), span: tg.span });
                this.recv_refs.put(d, r);
                pat = r;
            }
        }
    } else {
        return recv::NONE;
    }
    if (p.is_static) {
        return recv::STATIC(pat);
    }
    return recv::VAL(pat);
}

// a receiver pattern's type; `this: T*` takes its receiver like `this: T&`
attach fn recv_pat_type(this: checker&, pat: ty&, gps: std::vec<gparam>&, binds: std::vec<gval?>&, ns: u32) -> u32? {
    val t = this.resolve_partial(pat, gps, binds, ns) ?? return null;
    match (pat.kind) {
        .PTR(i) => {
            match (*this.t.get(t)) {
                .PTR(x) => { return this.t.intern(tyk::REF(x)); },
                default => {},
            }
        },
        default => {},
    }
    return t;
}

// Does a receiver of type r fit the pattern (binding its generics)? As it is, else by reference
// (the method takes a T&, r is a T), else through r's reference (r is a T&, the method takes a T).
attach fn match_recv(this: checker&, pat: ty&, r: u32, gps: std::vec<gparam>&, binds: std::vec<gval?>&, ns: u32) -> adj? {
    var b = copy *binds;
    this.infer(pat, r, gps, &b, ns);
    if ((this.recv_pat_type(pat, gps, &b, ns) ?? NO_TY) == r) {
        *binds = move b;
        return adj::NONE;
    }
    var inner: ty* = null;
    match (pat.kind) {
        .REF(i) => { inner = i; },
        .PTR(i) => { inner = i; },
        default => {},
    }
    if (inner) {
        val ip = inner;
        var b2 = copy *binds;
        this.infer(ip, r, gps, &b2, ns);
        if ((this.resolve_partial(ip, gps, &b2, ns) ?? NO_TY) == r) {
            *binds = move b2;
            return adj::REF;
        }
    }
    match (*this.t.get(r)) {
        .REF(d) => {
            var b3 = copy *binds;
            this.infer(pat, d, gps, &b3, ns);
            if ((this.recv_pat_type(pat, gps, &b3, ns) ?? NO_TY) == d) {
                *binds = move b3;
                return adj::DEREF;
            }
        },
        default => {},
    }
    return null;
}

fn no(m: std::string) -> bound {
    return bound::NO(move m);
}

fn is_pack_param(p: param&) -> bool {
    if (p.ty == null) {
        return false;
    }
    match (p.ty.value.kind) {
        .PACK(x) => { return true; },
        default => { return false; },
    }
}

// Bind a candidate's generics for a call; NO(reason) when it doesn't fit.
attach fn bind_cand(this: checker&, d: u32, rv: tval*, static_ty: u32?, explicit: std::vec<garg>&, args: std::vec<tval?>&) -> compile_error!bound {
    val f = this.fn_decl_of(d) ?? return no(S("not a function"));
    val fname = f.name;
    val ns = this.dl(d).ns;
    val gps = this.fn_generics(d);
    var binds = none_binds(gps.len);
    var a = adj::NONE;
    val rc = this.recv_of(d);
    if (rv) {
        val r = rv;
        if (static_ty != null) {
            return no(fmt("'{}' isn't a method", S(fname)));
        }
        match (rc) {
            .VAL(pat) => {
                a = this.match_recv(pat ?? return no(S("")), r.ty, gps, &binds, ns) ?? return no(fmt2("'{}' doesn't take a {} as this", S(fname), this.ty_name(r.ty)));
            },
            default => { return no(fmt("'{}' isn't a method", S(fname))); },
        }
    } else if (static_ty) {
        val t = static_ty;
        match (rc) {
            .STATIC(pat) => {
                val pt = pat ?? return no(S(""));
                this.infer(pt, t, gps, &binds, ns);
                if ((this.resolve_partial(pt, gps, &binds, ns) ?? NO_TY) != t) {
                    return no(fmt2("'{}' isn't attached to {}", S(fname), this.ty_name(t)));
                }
            },
            default => { return no(fmt2("'{}' isn't a static function of {} (static this)", S(fname), this.ty_name(t))); },
        }
    } else {
        match (rc) {
            .VAL(pat) => { return no(fmt2("'{}' is a method; call it as x.{}()", S(fname), S(fname))); },
            default => {},
        }
    }
    // explicit generic args fill the params the receiver left unbound, in order
    val caller = this.cx.env;
    var ei: usize = 0;
    for (i) in 0..gps.len {
        if (*binds.at(i) == null && ei < explicit.len) {
            val e = this.partial_env(ns, gps, &binds);
            val kind = try this.param_kind(gps.at(i), e);
            *binds.at(i) = try this.garg_gval(explicit.at(ei), kind, caller);
            ei += 1;
        }
    }
    if (ei < explicit.len) {
        return no(fmt("too many generic arguments for '{}'", S(fname)));
    }
    // check the argument count, then infer from the argument types (a comptime param takes the
    // argument's value, which has to be a literal)
    var vparams: std::vec<param*> = {};
    for (p&) in f.params.items() {
        if (p.name != "this") {
            put(&vparams, p);
        }
    }
    var has_pack = false;
    if (vparams.len > 0) {
        has_pack = is_pack_param(*vparams.at(vparams.len - 1) ?? return no(S("")));
    }
    var fixed = vparams.len;
    if (has_pack) {
        fixed -= 1;
    }
    var required: usize = 0;
    for (k) in 0..fixed {
        val p = *vparams.at(k) ?? continue;
        if (p.fallback == null) {
            required += 1;
        }
    }
    if (args.len < required || (args.len > fixed && !has_pack && !f.c_varargs)) {
        return no(fmt3("'{}' takes {} arguments, found {}", S(fname), unum(@cast<u64>(fixed)), unum(@cast<u64>(args.len))));
    }
    var k: usize = 0;
    while (k < fixed && k < args.len) {
        val p = *vparams.at(k) ?? return no(S(""));
        val av = *args.at(k);
        k += 1;
        if (p.is_comptime) {
            val j = gparam_index(gps, p.name) ?? return no(S(""));
            var got: gval? = null;
            if (av) {
                val v = av;
                match (v.lit ?? lit::FLOAT(0.0)) {
                    .INT(n) => {
                        if (v.lit != null) {
                            got = gval::INT(n);
                        }
                    },
                    .STR(s) => { got = gval::STR(s); },
                    default => {},
                }
                if (got == null && v.ty == BOOL) {
                    match (this.ir.at(v.c).kind) {
                        .BOOL(b) => {
                            if (b) {
                                got = gval::INT(1);
                            } else {
                                got = gval::INT(0);
                            }
                        },
                        default => {},
                    }
                }
            }
            *binds.at(j) = got ?? return no(fmt("the argument for comptime parameter '{}' must be known at compile time", S(p.name)));
            continue;
        }
        if (p.ty != null && av != null) {
            this.infer(&p.ty.value, (av ?? vnew(0, 0)).ty, gps, &binds, ns);
        }
    }
    // a pack binds to the types of all the remaining arguments
    if (has_pack) {
        val pp = *vparams.at(fixed) ?? return no(S(""));
        var tys: std::vec<u32> = {};
        for (m) in fixed..args.len {
            val av = *args.at(m) ?? return no(S("pack arguments need types that are known up front"));
            put(&tys, av.ty);
        }
        match (pp.ty.value.kind) {
            .PACK(inner) => {
                match (inner.kind) {
                    .PATH(ip) => {
                        if (ip.is_single()) {
                            val j = gparam_index(gps, ip.segs.at(0).name);
                            if (j) {
                                *binds.at(j) = gval::PACK(this.new_list(move tys));
                            }
                        }
                    },
                    default => {},
                }
            },
            default => {},
        }
    }
    // whatever is still unbound takes its default; an unbound pack is empty
    for (i) in 0..gps.len {
        if (*binds.at(i) != null) {
            continue;
        }
        val gp = gps.at(i);
        val e = this.partial_env(ns, gps, &binds);
        if (gp.fallback) {
            val kind = try this.param_kind(gp, e);
            *binds.at(i) = try this.garg_gval(gp.fallback, kind, e);
        } else if (gp.pack) {
            *binds.at(i) = gval::PACK(this.new_list({}));
        } else {
            return no(fmt3("can't infer '{}' for '{}'; pass it: {}<...>(...)", S(gp.name), S(fname), S(fname)));
        }
    }
    val out = unwrap_binds(&binds);
    val bad = try this.check_bounds(gps, &out, ns);
    if (bad) {
        return no(copy bad);
    }
    return bound::OK(move out, a);
}

// kinds match and trait bounds hold (null), or why not
attach fn check_bounds(this: checker&, gps: std::vec<gparam>&, binds: std::vec<gval>&, ns: u32) -> compile_error!(std::string?) {
    var e: env = { ns: ns };
    for (i) in 0..gps.len {
        if (i < binds.len) {
            put(&e.generics, { name: gps.at(i).name, g: *binds.at(i) });
        }
    }
    val env = this.new_env(move e);
    for (i) in 0..gps.len {
        if (i >= binds.len) {
            break;
        }
        val gp = gps.at(i);
        val b = *binds.at(i);
        val kind = try this.param_kind(gp, env);
        match (kind) {
            .TYPE => {
                match (b) {
                    .TY(t) => {
                        for (bt&) in gp.bounds.items() {
                            val bty = *bt ?? continue;
                            val tr = this.bound_trait(bty, ns);
                            if (tr) {
                                val trr = tr;
                                if (!(try this.satisfies(t, trr.decl, trr.args, env))) {
                                    return fmt3("{} = {} doesn't attach {}", S(gp.name), this.ty_name(t), S(this.decl_name(trr.decl)));
                                }
                            }
                        }
                    },
                    default => { return fmt("'{}' needs a type", S(gp.name)); },
                }
            },
            .CONST(t) => {
                match (b) {
                    .STR(s) => {
                        if (t != STR && t != CSTR) {
                            return fmt("'{}' needs a value", S(gp.name));
                        }
                    },
                    .INT(v) => {
                        val k = this.t.int_of(t);
                        if (k) {
                            val kk = k;
                            if (!kk.fits(v)) {
                                return fmt3("{} = {} doesn't fit in {}", S(gp.name), num(v), S(kk.name()));
                            }
                        }
                    },
                    default => { return fmt("'{}' needs a value", S(gp.name)); },
                }
            },
            .PACK => {
                match (b) {
                    .PACK(l) => {},
                    default => { return fmt("'{}' is a pack", S(gp.name)); },
                }
            },
        }
    }
    return null;
}

attach fn decl_name(this: checker&, d: u32) -> str {
    match (this.item_of(d).kind) {
        .FN(f) => { return f.name; },
        .STRUCT(s) => { return s.name; },
        .ENUM(e) => { return e.name; },
        .TRAIT(n, fs) => { return n; },
        .GLOBAL(l&) => {
            match (l.pat.kind) {
                .BIND(n) => { return n; },
                default => { return "?"; },
            }
        },
        default => { return "?"; },
    }
}

// does ty attach the trait (with these args)?
// A trait union attaches its own trait; any other type needs an attach block for the trait whose
// target matches it, with the same trait args.
attach fn satisfies(this: checker&, t: u32, trait_decl: u32, targs: std::vec<garg>*, e: u32) -> compile_error!bool {
    match (*this.t.get(t)) {
        .TRAIT_UNION(u) => {
            if (this.ui(u).trait_decl == trait_decl) {
                return true;
            }
        },
        default => {},
    }
    var want: std::vec<u32> = {};
    if (targs) {
        for (g&) in (targs).items() {
            put(&want, try this.garg_type_env(g, e));
        }
    }
    val blocks = copy this.attach_blocks;
    for (b&) in blocks.items() {
        val ns = this.dl(*b).ns;
        match (this.item_of(*b).kind) {
            .ATTACH(tr&, target&, fs) => {
                val bt = this.bound_trait(tr, ns) ?? continue;
                if (bt.decl != trait_decl) {
                    continue;
                }
                val gps = this.gparams_of(*b);
                var binds = none_binds(gps.len);
                this.infer(target, t, gps, &binds, ns);
                if ((this.resolve_partial(target, gps, &binds, ns) ?? NO_TY) != t) {
                    continue;
                }
                val penv = this.partial_env(ns, gps, &binds);
                var got: std::vec<u32> = {};
                var ok = true;
                if (bt.args) {
                    for (g&) in (bt.args).items() {
                        val x = this.garg_type_env(g, penv) catch |er| {
                            ok = false;
                            break;
                        };
                        put(&got, x);
                    }
                }
                if (ok && same_list(&got, &want)) {
                    return true;
                }
            },
            default => {},
        }
    }
    return false;
}

// ---------- calls ----------

// arguments that can't be checked without an expected type (aggregate literals, .VARIANT, null,
// closures with untyped params); calls check them against the chosen candidate's params
fn needs_context(e: expr&) -> bool {
    match (e.kind) {
        .LITERAL(x) => { return true; },
        .DOT_VARIANT(x) => { return true; },
        .NULL => { return true; },
        .CLOSURE(c) => {
            for (p&) in c.params.items() {
                if (p.ty == null) {
                    return true;
                }
            }
            return false;
        },
        .CALL(c, a) => {
            match (c.kind) {
                .DOT_VARIANT(x) => { return true; },
                default => { return false; },
            }
        },
        default => { return false; },
    }
}

// can decl d take n arguments (receiver not counted)?
attach fn arity_fits(this: checker&, d: u32, n: usize) -> bool {
    val f = this.fn_decl_of(d) ?? return false;
    var count: usize = 0;
    var no_default: usize = 0;
    var pack = false;
    for (p&) in f.params.items() {
        if (p.name == "this") {
            continue;
        }
        count += 1;
        if (p.fallback == null) {
            no_default += 1;
        }
        pack = is_pack_param(p);
    }
    var required = no_default;
    if (pack) {
        required -= 1;
    }
    return n >= required && (n <= count || pack || f.c_varargs);
}

// a candidate that fits a call: its instance, receiver adjustment, score and blanket positions
struct viable {
    inst: u32;
    a: adj;
    score: i32;
    blanket: i32;
}

// whether t is a bare generic parameter of gps (T, T&, T*, T...)
fn bare_generic(t: ty&, gps: std::vec<gparam>&) -> bool {
    var p: path* = null;
    match (t.kind) {
        .PATH(x&) => { p = x; },
        .REF(i) => {
            match (i.kind) {
                .PATH(x&) => { p = x; },
                default => {},
            }
        },
        .PTR(i) => {
            match (i.kind) {
                .PATH(x&) => { p = x; },
                default => {},
            }
        },
        .PACK(i) => {
            match (i.kind) {
                .PATH(x&) => { p = x; },
                default => {},
            }
        },
        default => {},
    }
    val q = p ?? return false;
    if (!q->is_single()) {
        return false;
    }
    for (g&) in gps.items() {
        if (g.name == q->segs.at(0).name) {
            return true;
        }
    }
    return false;
}

// How many of a fn's receiver and parameters are a bare generic parameter (T, T&, T*, T...): a blanket
// version (`<T> eq(this: T&, other: T&)`) has more than one written for a type (`string<A>&`)
attach fn blanket_positions(this: checker&, d: u32) -> i32 {
    val f = this.fn_decl_of(d) ?? return 0;
    val gps = this.fn_generics(d);
    var n = 0;
    match (this.recv_of(d)) {
        .VAL(pat) => {
            if (bare_generic(pat ?? return 0, gps)) {
                n += 1;
            }
        },
        .STATIC(pat) => {
            if (bare_generic(pat ?? return 0, gps)) {
                n += 1;
            }
        },
        default => {},
    }
    for (p&) in f.params.items() {
        if (p.name != "this" && p.ty != null && bare_generic(&p.ty.value, gps)) {
            n += 1;
        }
    }
    return n;
}

// Pick one of the overloads cands for a call and emit it. Every candidate that fits is scored:
// per argument 3 for its exact type, 1 for a coercion; 2 when it returns the wanted type, 1 when
// it isn't generic. The best score has to be unique, or the call is ambiguous; between equal
// scores, the one with fewer blanket positions (more specific) wins.
attach fn resolve_call(this: checker&, name: str, cands: std::vec<u32>&, rv: tval?, static_ty: u32?, explicit: std::vec<garg>&, args: std::vec<expr>&, want: u32?, span: span) -> compile_error!tval {
    if (cands.len == 1) {
        val intr = intrinsic_of(this.item_of(*cands.at(0)));
        if (intr) {
            val i = intr;
            if (i == "println" || i == "print" || i == "eprintln" || i == "eprint" || i == "write" || i == "format") {
                if (this.opts.lsp) {
                    this.lsp_fn_use(*cands.at(0), null, span);
                }
                // format makes a value of the type its declaration returns (std says std::string)
                var ret = VOID;
                if (i == "format") {
                    val d = *cands.at(0);
                    match (this.item_of(d).kind) {
                        .FN(f&) => {
                            if (f.ret) {
                                val e = this.new_env({ ns: this.decls.at(@cast<usize>(d)).ns });
                                ret = try this.resolve_type(&f.ret, e);
                            }
                        },
                        default => {},
                    }
                }
                return this.intrinsic(i, args, ret, span);
            }
        }
    }
    var rp: tval* = null;
    var rcopy = rv ?? vnew(0, 0);
    if (rv) {
        rp = &rcopy;
    }
    // one candidate takes this many arguments: its parameter types can guide them (so a
    // return-type overload in an argument gets its context), if they don't hang on the arguments
    var wants: std::vec<u32?> = {};
    for (k) in 0..args.len {
        put(&wants, null);
    }
    var fits: std::vec<u32> = {};
    for (d&) in cands.items() {
        if (this.arity_fits(*d, args.len)) {
            put(&fits, *d);
        }
    }
    if (fits.len == 1) {
        val d = *fits.at(0);
        var inst: u32? = null;
        if (this.fn_generics(d).len == 0) {
            inst = try this.fn_inst(d, {}, span);
        } else {
            var unknown: std::vec<tval?> = {};
            for (k) in 0..args.len {
                put(&unknown, null);
            }
            val b = this.bind_cand(d, rp, static_ty, explicit, &unknown) catch |x| { return this.resolve_rest(name, cands, rp, static_ty, explicit, args, want, span, &wants); };
            match (b) {
                .OK(binds, a) => {
                    val i = this.fn_inst(d, copy binds, span) catch |x| { return this.resolve_rest(name, cands, rp, static_ty, explicit, args, want, span, &wants); };
                    inst = i;
                },
                default => {},
            }
        }
        if (inst) {
            var off: usize = 0;
            if (rp != null) {
                off = 1;
            }
            val fp = &this.fi(inst).params;
            for (k) in 0..wants.len {
                if (k + off < fp.len) {
                    *wants.at(k) = fp.at(k + off).ty;
                }
            }
        }
    }
    return this.resolve_rest(name, cands, rp, static_ty, explicit, args, want, span, &wants);
}

// resolve_call once the argument contexts (wants) are known. Arguments are checked once, before
// choosing; those needing context wait for emit_call
attach fn resolve_rest(this: checker&, name: str, cands: std::vec<u32>&, rp: tval*, static_ty: u32?, explicit: std::vec<garg>&, args: std::vec<expr>&, want: u32?, span: span, wants: std::vec<u32?>&) -> compile_error!tval {
    var pre: std::vec<tval?> = {};
    for (k) in 0..args.len {
        val a = args.at(k);
        if (needs_context(a)) {
            put(&pre, null);
        } else {
            put(&pre, try this.expr(a, *wants.at(k)));
        }
    }
    var vs: std::vec<viable> = {};
    // why each candidate doesn't fit; a lone one is the error itself
    var reasons: std::vec<diag> = {};
    for (dp&) in cands.items() {
        val d = *dp;
        val b = try this.bind_cand(d, rp, static_ty, explicit, &pre);
        var binds: std::vec<gval> = {};
        var a = adj::NONE;
        match (b) {
            .OK(bs, x) => {
                binds = copy bs;
                a = x;
            },
            .NO(r) => {
                put(&reasons, { span: span, msg: copy r });
                continue;
            },
        }
        val inst = this.fn_inst(d, move binds, span) catch |e| {
            put(&reasons, err_diag(&e));
            continue;
        };
        val f = this.fi(inst);
        var offset: usize = 0;
        if (rp != null) {
            offset = 1;
        }
        var fixed = f.params.len - offset;
        if (f.pack) {
            fixed -= 1;
        }
        var score: i32 = 0;
        var ok = true;
        var i: usize = 0;
        while (i < pre.len && i < fixed) {
            val v = *pre.at(i);
            if (v != null && i + offset < f.params.len) {
                val vv = v ?? vnew(0, 0);
                val pt = f.params.at(i + offset).ty;
                if (vv.ty == pt) {
                    score += 3;
                } else if (this.coercible(&vv, pt)) {
                    score += 1;
                } else {
                    ok = false;
                    var m = fmt3("argument {} is a {}, but '{}' wants a ", unum(@cast<u64>(i + 1)), this.ty_name(vv.ty), S(name));
                    this.put_ty(&m, pt);
                    var r: diag = { span: args.at(i).span, msg: move m };
                    val fd = this.fn_decl_of(d);
                    if (fd) {
                        for (ap&) in fd.params.items() {
                            if (ap.name == f.params.at(i + offset).name) {
                                put(&r.labels, { span: ap.span, msg: S("parameter declared here") });
                                break;
                            }
                        }
                    }
                    put(&reasons, move r);
                    break;
                }
            }
            i += 1;
        }
        if (!ok) {
            continue;
        }
        if (want != null && (want ?? 0) == f.ret) {
            score += 2;
        }
        if (this.fn_generics(d).len == 0) {
            score += 1;
        }
        put(&vs, { inst: inst, a: a, score: score, blanket: this.blanket_positions(d) });
    }
    // stable sort, best first: by score, then fewer blanket positions (more specific)
    for (x) in 1..vs.len {
        var j = x;
        while (j > 0 && (vs.at(j - 1).score < vs.at(j).score || (vs.at(j - 1).score == vs.at(j).score && vs.at(j - 1).blanket > vs.at(j).blanket))) {
            val t = *vs.at(j);
            *vs.at(j) = *vs.at(j - 1);
            *vs.at(j - 1) = t;
            j -= 1;
        }
    }
    if (vs.len == 0) {
        if (reasons.len == 1) {
            return compile_error::AT(copy *reasons.at(0));
        }
        var m = S("no version of '");
        m.append(name);
        m.append("' fits: ");
        for (k) in 0..reasons.len {
            if (k > 0) {
                m.append("; ");
            }
            m.append(reasons.at(k).msg.as_str());
        }
        return fail(span, move m);
    }
    if (vs.len > 1 && vs.at(0).score == vs.at(1).score && vs.at(0).blanket == vs.at(1).blanket) {
        return fail(span, fmt("call to '{}' is ambiguous (several versions fit); add types to the arguments or the result", S(name)));
    }
    val pick = *vs.at(0);
    var r: tval? = null;
    if (rp) {
        r = *(rp);
    }
    return this.emit_call(pick.inst, pick.a, r, &pre, args, span);
}

// Emit a call of fn instance inst: adjust the receiver, convert the arguments (a pack's become one
// tuple, C varargs are promoted), and fill in defaults, checked in the callee's env. A temporary
// made to pass a receiver by reference is deleted after the call.
attach fn emit_call(this: checker&, inst: u32, a: adj, rv: tval?, pre: std::vec<tval?>&, args: std::vec<expr>&, span: span) -> compile_error!tval {
    if (this.opts.lsp) {
        this.lsp_fn_use(this.fi(inst).decl, inst, span);
    }
    try this.visible(this.fi(inst).decl, span);
    val fp = this.fi(inst);
    val (pack, fenv, fir, fret) = (fp.pack, fp.env, fp.ir, fp.ret);
    val nparams = fp.params.len;
    var vals: std::vec<tval> = {};
    var prefix: std::vec<u32> = {};
    var post: u32? = null;
    if (rv) {
        val r = rv;
        // what the receiver lends this: the place itself (REF), or the reference it is (NONE)
        match (a) {
            .REF => {
                // a temporary's slot is fresh, but what it points at may not be
                this.note_mut(&r);
                var x = vnew(0, 0);
                addr_prov(&x, &r);
                this.note_arg(body_key(BODY_FN, inst), 0, &x, span);
            },
            .NONE => { this.note_arg(body_key(BODY_FN, inst), 0, &r, span); },
            default => {},
        }
        match (a) {
            .NONE => {
                var v = try this.take(r, span);
                v.ty = this.fi(inst).params.at(0).ty;
                put(&vals, v);
            },
            .DEREF => {
                val d = this.t.ref_inner(r.ty) ?? r.ty;
                var v = r;
                v.ty = d;
                v.c = this.ir.deref(r.c, d);
                v.lv = true;
                put(&vals, v);
            },
            .REF => {
                val rt = this.t.ref_to(r.ty);
                if (r.lv) {
                    var v = r;
                    v.ty = rt;
                    v.c = this.ir.addr(r.c, rt);
                    v.lv = false;
                    put(&vals, v);
                } else if (this.cx.keeping) {
                    // kept to the end of the statement (see fn_cx.kept); its owner initializes the
                    // flag, and an exit from the statement's scope deletes it from here on
                    val t = this.slot("_rv", r.ty);
                    val flag = this.flag_for(t);
                    put(&prefix, this.ir.assign(t, r.c));
                    put(&prefix, this.ir.assign(flag, this.ir.boolean(true)));
                    if (try this.needs_drop(r.ty)) {
                        val d = try this.drop_fn(r.ty);
                        put(&this.cx.scopes.at(this.cx.keep_scope).exits, exit::DROP(t, d, flag));
                    }
                    put(&this.cx.kept, { c: t, ty: r.ty, flag: flag });
                    put(&vals, vpure(rt, this.ir.addr(t, rt)));
                } else {
                    val t = this.tmp_local("rv", r.ty);
                    put(&prefix, this.ir.decl(t.id, r.c));
                    if (try this.needs_drop(r.ty)) {
                        val d = try this.drop_fn(r.ty);
                        post = this.call_fn(d, nodes(this.ir.addr(t.c, rt)), VOID);
                    }
                    put(&vals, vpure(rt, this.ir.addr(t.c, rt)));
                }
            },
        }
    }
    // the fixed arguments convert to their parameter types (comptime ones are part of the instance)
    val offset = vals.len;
    var fixed = nparams - offset;
    if (pack) {
        fixed -= 1;
    }
    var i: usize = 0;
    while (i < args.len && i < fixed) {
        val p = *this.fi(inst).params.at(i + offset);
        if (!p.is_comptime) {
            var v = *pre.at(i) ?? vnew(0, 0);
            if (*pre.at(i) == null) {
                v = try this.expr(args.at(i), p.ty);
            }
            val tv = try this.take_into(v, p.ty, args.at(i).span);
            this.note_arg(body_key(BODY_FN, inst), i + offset, &tv, args.at(i).span);
            if (this.opts.lsp) {
                put(&this.lsp_args, { at: args.at(i).span, name: p.name });
            }
            put(&vals, tv);
        }
        i += 1;
    }
    // the rest: one tuple for a pack, else C varargs
    if (pack) {
        val pt = this.fi(inst).params.at(nparams - 1).ty;
        var inits: std::vec<field_init> = {};
        var k: u32 = 0;
        for (m) in fixed..args.len {
            var v = *pre.at(m) ?? vnew(0, 0);
            if (*pre.at(m) == null) {
                v = try this.expr(args.at(m), null);
            }
            put(&inits, { field: k, value: v.c });
            k += 1;
        }
        if (pt != VOID) {
            put(&vals, vnew(pt, this.ir.node(ir_kind::AGG(move inits), pt)));
        }
    } else if (args.len > fixed) {
        for (m) in fixed..args.len {
            var v = *pre.at(m) ?? vnew(0, 0);
            if (*pre.at(m) == null) {
                v = try this.expr(args.at(m), null);
            }
            put(&vals, try this.vararg_val(v, args.at(m).span));
        }
    }
    // parameters left out take their defaults, checked in the callee's env
    var start = offset + fixed;
    if (args.len < fixed) {
        start = offset + args.len;
    }
    for (j) in start..(offset + fixed) {
        val p = *this.fi(inst).params.at(j);
        if (p.is_comptime) {
            continue;
        }
        val d = p.fallback ?? return fail(span, fmt("missing argument '{}'", S(p.name)));
        put(&vals, try this.in_env_expr_as(fenv, d, p.ty));
    }
    this.use_fn(inst);
    this.warn_deprecated(inst, span);
    var seq = this.seq_vals(&vals);
    var cs: std::vec<u32> = {};
    for (v&) in vals.items() {
        put(&cs, v.c);
    }
    val fnode = this.ir.node(ir_kind::FN(fir), VOIDPTR);
    val direct = this.ir.call(fnode, move cs, fret);
    val ac = try this.async_call(inst, direct, span);
    for (s&) in seq.items() {
        put(&prefix, *s);
    }
    if (post) {
        if (ac.ty == VOID || ac.ty == NEVER) {
            put(&prefix, ac.c);
            put(&prefix, post);
            return vnew(ac.ty, this.ir.seq(move prefix, null, ac.ty));
        }
        val t = this.tmp_local("cr", ac.ty);
        put(&prefix, this.ir.decl(t.id, ac.c));
        put(&prefix, post);
        return vnew(ac.ty, this.ir.seq(move prefix, t.c, ac.ty));
    }
    return vnew(ac.ty, this.wrap_pre(move prefix, ac.c, ac.ty));
}

// x.name(args): fn-typed field, trait-union dispatch, or an attached method
attach fn method_call(this: checker&, r: tval, name: str, gargs: std::vec<garg>&, args: std::vec<expr>&, want: u32?, span: span) -> compile_error!tval {
    if (name == "delete") {
        return fails(span, "delete runs by itself when the owner goes out of scope; it can't be called by hand");
    }
    match (*this.t.get(r.ty)) {
        .PTR(x) => { return fail(span, fmt2("this is a pointer ({}); call through it with ->: p->{}()", this.ty_name(r.ty), S(name))); },
        default => {},
    }
    val base = this.t.ref_inner(r.ty) ?? r.ty;
    // an owning pointer (@owns, like std's box) is used like a T&: methods go to what it points at
    val own = this.owner(base);
    if (own) {
        val o = own;
        var place = r.c;
        if (base != r.ty) {
            place = this.ir.deref(r.c, base);
        }
        val rt = this.t.ref_to(o.inner);
        val access = this.ir.field(place, o.index, rt);
        var v = vnew(rt, access);
        v.pure = r.pure;
        return this.method_call(v, name, gargs, args, want, span);
    }
    match (*this.t.get(base)) {
        .STRUCT(sid) => {
            val fs = try this.struct_fields(sid, span);
            for (f&) in fs.items() {
                if (f.name == name) {
                    match (*this.t.get(f.ty)) {
                        .FN_PTR(ps, rt, va) => {
                            val fv = try this.field(r, name, span);
                            return this.call_value(fv, args, span);
                        },
                        default => {},
                    }
                }
            }
        },
        .TRAIT_UNION(u) => { return this.union_call(r, u, name, gargs, args, want, span); },
        default => {},
    }
    var cands: std::vec<u32> = {};
    for (d&) in this.named(&this.attached, name).items() {
        match (this.recv_of(*d)) {
            .VAL(x) => { put(&cands, *d); },
            default => {},
        }
    }
    if (cands.len == 0) {
        return fail(span, fmt2("{} has no method '{}'", this.ty_name(r.ty), S(name)));
    }
    return this.resolve_call(name, &cands, r, null, gargs, args, want, span);
}

// Type::name(args) for static attached fns
attach fn static_call(this: checker&, t: u32, name: str, gargs: std::vec<garg>&, args: std::vec<expr>&, want: u32?, span: span) -> compile_error!tval {
    var cands: std::vec<u32> = {};
    for (d&) in this.named(&this.attached, name).items() {
        match (this.recv_of(*d)) {
            .STATIC(x) => { put(&cands, *d); },
            default => {},
        }
    }
    if (cands.len == 0) {
        return fail(span, fmt2("{} has no static function '{}'", this.ty_name(t), S(name)));
    }
    return this.resolve_call(name, &cands, null, t, gargs, args, want, span);
}

// an item's @intrinsic("name")
fn intrinsic_of(it: item&) -> str? {
    for (a&) in it.attrs.items() {
        match (a.kind) {
            .BUILTIN(n, g, args) => {
                if (n != "intrinsic" || args == null) {
                    continue;
                }
                if (args.value.len == 0) {
                    continue;
                }
                match (*args.value.at(0)) {
                    .EXPR(x) => {
                        match (x.kind) {
                            .STR(s) => { return s.as_str(); },
                            default => {},
                        }
                    },
                    default => {},
                }
            },
            default => {},
        }
    }
    return null;
}

// ---------- trait unions ----------

// The trait union for a trait, made once: every type a non-generic attach block attaches the
// trait to is a member. Fails if no type attaches it.
attach fn trait_union(this: checker&, trait_decl: u32, span: span) -> compile_error!u32 {
    val have = this.union_ids.get(trait_decl);
    if (have) {
        return this.t.intern(tyk::TRAIT_UNION(*have));
    }
    val name = this.decl_name(trait_decl);
    val id = @cast<u32>(this.unions.len);
    var base = S("v_");
    base.append(name);
    val c_name = this.fresh_c_name(base.as_str());
    put(&this.unions, bx<union_info>({ trait_decl: trait_decl, name: name, c_name: c_name }));
    this.union_ids.put(trait_decl, id);
    var members: std::vec<u32> = {};
    val blocks = copy this.attach_blocks;
    for (b&) in blocks.items() {
        val ns = this.dl(*b).ns;
        if (this.item_of(*b).generics.len > 0) {
            continue;
        }
        match (this.item_of(*b).kind) {
            .ATTACH(tr&, target&, fs) => {
                val bt = this.bound_trait(tr, ns) ?? continue;
                if (bt.decl != trait_decl) {
                    continue;
                }
                val e = this.new_env({ ns: ns });
                val t = try this.resolve_type(target, e);
                var dup = false;
                for (m&) in members.items() {
                    if (*m == t) {
                        dup = true;
                    }
                }
                if (!dup) {
                    put(&members, t);
                }
            },
            default => {},
        }
    }
    if (members.len == 0) {
        return fail(span, fmt("no type attaches {}, so it can't be used as a type", S(name)));
    }
    this.ui(id).members = move members;
    return this.t.intern(tyk::TRAIT_UNION(id));
}

// m's index (its tag) in trait union t, if it's one of its members
attach fn union_member(this: checker&, t: u32, m: u32) -> usize? {
    match (*this.t.get(t)) {
        .TRAIT_UNION(u) => {
            val ms = &this.ui(u).members;
            for (i) in 0..ms.len {
                if (*ms.at(i) == m) {
                    return i;
                }
            }
            return null;
        },
        default => { return null; },
    }
}

// x.name() on a trait union: a switch on the tag that calls the method on each member type; the
// results coerce to the first member's result type
attach fn union_call(this: checker&, r: tval, u: u32, name: str, gargs: std::vec<garg>&, args: std::vec<expr>&, want: u32?, span: span) -> compile_error!tval {
    val uty = this.t.intern(tyk::TRAIT_UNION(u));
    val upt = this.t.ref_to(uty);
    val up = this.tmp_local("u", upt);
    var head: std::vec<u32> = {};
    var ptr = r.c;
    match (*this.t.get(r.ty)) {
        .REF(x) => {},
        default => {
            if (r.lv) {
                ptr = this.ir.addr(r.c, upt);
            } else {
                val t = this.tmp_local("uv", uty);
                put(&head, this.ir.decl(t.id, r.c));
                ptr = this.ir.addr(t.c, upt);
            }
        },
    }
    put(&head, this.ir.decl(up.id, ptr));
    val members = copy this.ui(u).members;
    var cases: std::vec<case_arm> = {};
    var rty: u32? = null;
    var result: local_ref? = null;
    val obj = this.ir.deref(up.c, uty);
    // one case runs, so moves are tracked per case as per match arm: each starts from the moves
    // before the call, and the code after sees them all
    val base = copy this.cx.moved;
    var after = copy base;
    for (i) in 0..members.len {
        this.cx.moved = copy base;
        val m = *members.at(i);
        var mv = vpure(m, this.ir.field(obj, @cast<u32>(i) + 1, m));
        mv.lv = true;
        mv.mutable = true;
        var w = want;
        if (rty) {
            w = rty;
        }
        var v = try this.method_call(mv, name, gargs, args, w, span);
        after.add_all(&this.cx.moved);
        if (rty == null) {
            rty = v.ty;
        } else if (v.ty != NEVER && (rty ?? 0) != VOID) {
            v = try this.coerce(v, rty ?? 0, span);
        }
        val rt = rty ?? VOID;
        var body: std::vec<u32> = {};
        if (rt == VOID || rt == NEVER || v.ty == NEVER) {
            put(&body, v.c);
        } else {
            if (result == null) {
                result = this.tmp_local("ur", rt);
            }
            put(&body, this.ir.assign((result ?? { id: 0, c: 0 }).c, v.c));
        }
        put(&cases, { value: @cast<i128>(i), body: this.ir.block(move body) });
    }
    this.cx.moved = move after;
    val rt = rty ?? VOID;
    val tag = this.ir.field(obj, 0, int_id(int_ty::U16));
    if (rt == VOID || rt == NEVER) {
        put(&head, this.ir.node(ir_kind::SWITCH(tag, move cases, null), VOID));
        return vnew(VOID, this.ir.seq(move head, null, VOID));
    }
    val res = result ?? this.tmp_local("ur", rt);
    put(&head, this.ir.decl(res.id, null));
    put(&head, this.ir.node(ir_kind::SWITCH(tag, move cases, this.ir.node(ir_kind::UNREACHABLE, NEVER)), VOID));
    return vnew(rt, this.ir.seq(move head, res.c, rt));
}

// ---------- Type::member paths ----------

// Type::name: a member of a type, or a variant of a generic enum written without its args
attach fn member_path(this: checker&, p: path&) -> compile_error!(member?) {
    if (p.segs.len < 2) {
        return null;
    }
    var segs: std::vec<path_seg> = {};
    for (i) in 0..(p.segs.len - 1) {
        put(&segs, copy *p.segs.at(i));
    }
    val prefix: path = { segs: move segs, span: p.span };
    val e = this.cx.env;
    val t = this.resolve_type_path(&prefix, e) catch |x| {
        val family = this.pattern_family(&prefix, this.env_at(e).ns);
        if (family) {
            try this.visible(family, p.span); // an internal type of another package: say so, not "unknown name"
        }
        return this.generic_enum_member(&prefix, p.last(), e);
    };
    return member::OF(t, p.last());
}

// a generic enum written without its args: generic_enum::VALUE(1)
attach fn generic_enum_member(this: checker&, prefix: path&, last: str, e: u32) -> member? {
    if (prefix.segs.at(prefix.segs.len - 1).args != null) {
        return null;
    }
    val d = this.pattern_family(prefix, this.env_at(e).ns) ?? return null;
    match (this.item_of(d).kind) {
        .ENUM(x) => {
            if (this.item_of(d).generics.len > 0) {
                return member::GENERIC_ENUM(d, last);
            }
        },
        default => {},
    }
    return null;
}

// pick the instance of a generic enum for a variant from the expected type or the payload
attach fn infer_enum(this: checker&, d: u32, variant: str, args: std::vec<expr>*, want: u32?, span: span) -> compile_error!u32 {
    if (want) {
        var inner = want;
        match (*this.t.get(inner)) {
            .ERR_UNION(e, t) => { inner = e; },
            .OPT(i) => { inner = i; },
            default => {},
        }
        match (*this.t.get(inner)) {
            .ENUM(e) => {
                if (this.ei(e).family == d) {
                    return inner;
                }
            },
            default => {},
        }
    }
    val ns = this.dl(d).ns;
    var ed: enum_decl* = null;
    match (this.item_of(d).kind) {
        .ENUM(e&) => { ed = e; },
        default => {},
    }
    val en = ed ?? return fails(span, "not an enum");
    val gps = this.gparams_of(d);
    var binds = none_binds(gps.len);
    var vd: variant* = null;
    for (v&) in en.variants.items() {
        if (v.name == variant) {
            vd = v;
            break;
        }
    }
    val v = vd ?? return fail(span, fmt2("{} has no variant {}", S(en.name), S(variant)));
    // the payload is only checked here for its type; the real check (make_variant) comes later, so
    // moves made here are undone
    var moved_before = copy this.cx.moved;
    if (v.payload != null && args != null) {
        val pt = &v.payload.value;
        val a = args ?? return fails(span, "");
        if (a.len == 1) {
            val av = try this.expr(a.at(0), null);
            this.infer(pt, av.ty, gps, &binds, ns);
        } else {
            match (pt.kind) {
                .TUPLE(ps) => {
                    var k: usize = 0;
                    while (k < ps.len && k < a.len) {
                        val av = try this.expr(a.at(k), null);
                        this.infer(&ps.at(k).ty, av.ty, gps, &binds, ns);
                        k += 1;
                    }
                },
                default => {},
            }
        }
    }
    this.cx.moved = move moved_before;
    var out: std::vec<gval> = {};
    for (i) in 0..gps.len {
        val gp = gps.at(i);
        val e = this.partial_env(ns, gps, &binds);
        var b = *binds.at(i);
        if (b == null) {
            if (gp.fallback) {
                val kind = try this.param_kind(gp, e);
                b = try this.garg_gval(gp.fallback, kind, e);
            } else {
                return fail(span, fmt4("can't tell '{}' for {}; write {}<...>::{}", S(gp.name), S(en.name), S(en.name), S(variant)));
            }
        }
        *binds.at(i) = b;
        put(&out, b ?? gval::INT(0));
    }
    return this.enum_inst(d, move out, span);
}
