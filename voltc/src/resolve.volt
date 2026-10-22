// Types from syntax, struct/fn instances, constants and globals: a port of the rest of
// bootstrap/check/mod.rs (the program root is in program.volt).
use std::mem;

// the type a type expression denotes in env e (its generic params bound)
attach fn resolve_type(this: checker&, t: ty&, e: u32) -> compile_error!u32 {
    match (t.kind) {
        .PATH(p&) => { return this.resolve_type_path(p, e); },
        .REF(inner) => {
            val i = try this.resolve_type(inner, e);
            if (i == VOID) {
                return fails(t.span, "void& isn't a type; an untyped pointer is void*");
            }
            return this.t.intern(tyk::REF(i));
        },
        .PTR(inner) => {
            val i = try this.resolve_type(inner, e);
            if (i == VOID) {
                return VOIDPTR;
            }
            return this.t.intern(tyk::PTR(i));
        },
        .OPTIONAL(inner) => {
            match (inner.kind) {
                .REF(x) => { return fails(t.span, "a reference (T&) is never null, so it can't be optional; a pointer that may be null is T*"); },
                .PTR(x) => { return fails(t.span, "a pointer (T*) can already be null; drop the ?"); },
                default => {},
            }
            val i = try this.resolve_type(inner, e);
            return this.t.intern(tyk::OPT(i));
        },
        .ARRAY(inner, n) => {
            val i = try this.resolve_type(inner, e);
            if (n) {
                val len = try this.const_int(n, e);
                val l = try array_len(len, n.span);
                return this.t.intern(tyk::ARRAY(i, l));
            }
            return fails(t.span, "T[] takes its length from an initializer, so it only works on a var/val with one");
        },
        .SLICE(inner) => {
            val i = try this.resolve_type(inner, e);
            return this.t.intern(tyk::SLICE(i));
        },
        .TUPLE(elems) => {
            var ts: std::vec<u32> = {};
            var names: std::vec<str?> = {};
            for (el&) in elems.items() {
                put(&ts, try this.resolve_type(&el.ty, e));
                put(&names, el.name);
            }
            if (ts.len == 0) {
                return VOID;
            }
            return this.t.intern(tyk::TUPLE(move ts, move names));
        },
        .FN(f) => {
            var ps: std::vec<u32> = {};
            for (p&) in f.params.items() {
                put(&ps, try this.resolve_type(p, e));
            }
            val r = try this.resolve_type(f.ret, e);
            if (f.extern_c) {
                return this.t.intern(tyk::FN_PTR(move ps, r, f.c_varargs));
            }
            if (f.c_varargs) {
                return fails(t.span, "only extern \"C\" fn types can take C varargs");
            }
            return this.t.intern(tyk::FN_VAL(move ps, r));
        },
        .ERROR_UNION(es, inner) => {
            var err_ty = ANYERR;
            if (es) {
                err_ty = try this.resolve_type(es, e);
                if (!this.is_error_ty(err_ty)) {
                    return fail(es.span, fmt("{} isn't an error set", this.ty_name(err_ty)));
                }
            }
            val i = try this.resolve_type(inner, e);
            return this.t.intern(tyk::ERR_UNION(err_ty, i));
        },
        .PACK(x) => { return fails(t.span, "a pack type (T...) only works on the last parameter"); },
        .EXPR(x) => {
            val v = try this.ct_eval_in(e, x, TYPE);
            match (v) {
                .TYPE(r) => { return r; },
                default => { return fails(x.span, "this doesn't give a type"); },
            }
        },
        .RESOLVED(r) => { return r; },
    }
}

// a type written as a struct { } / enum { } body right there
fn is_type_body(t: ty&) -> bool {
    match (t.kind) {
        .EXPR(x) => {
            match (x.kind) {
                .TYPE_BODY(b) => { return true; },
                default => { return false; },
            }
        },
        default => { return false; },
    }
}

// the generic bound to name in an env (innermost first)
// a generic value parameter's declared type (<N: usize>'s usize): its one bound
fn param_ty(gp: gparam&) -> ty* {
    if (gp.bounds.len == 1) {
        return *gp.bounds.at(0);
    }
    return null;
}

// the declared type of generic param `name` bound in env e (null: none, or not a value parameter)
attach fn env_generic_ty(this: checker&, e: u32, name: str) -> ty* {
    val gs = &this.env_at(e).generics;
    var i = gs.len;
    while (i > 0) {
        i -= 1;
        if (gs.at(i).name == name) {
            return gs.at(i).ty;
        }
    }
    return null;
}

attach fn env_generic(this: checker&, e: u32, name: str) -> gval? {
    val gs = &this.env_at(e).generics;
    var i = gs.len;
    while (i > 0) {
        i -= 1;
        if (gs.at(i).name == name) {
            return gs.at(i).g;
        }
    }
    return null;
}

// A named type: a generic param, a primitive, a comptime type constant, or a struct, enum or
// trait decl instantiated with its generic args (a trait used as a type is a trait union).
attach fn resolve_type_path(this: checker&, p: path&, e: u32) -> compile_error!u32 {
    // a single name: a generic param, a primitive or a comptime type constant
    if (p.is_single()) {
        val name = p.segs.at(0).name;
        val g = this.env_generic(e, name);
        if (g) {
            match (g) {
                .TY(t) => {
                    if (this.opts.lsp) {
                        this.lsp_tparam_use(name, p.span, t);
                    }
                    return t;
                },
                .PACK(l) => {
                    if (this.list(l).len == 0) {
                        return VOID;
                    }
                    var names: std::vec<str?> = {};
                    for (i) in 0..this.list(l).len {
                        put(&names, null);
                    }
                    return this.t.intern(tyk::TUPLE(copy *this.list(l), move names));
                },
                default => { return fail(p.span, fmt("'{}' is a value, not a type", S(name))); },
            }
        }
        val prim = primitive(name);
        if (prim) {
            return prim;
        }
        val c = this.const_or_ct_local(name);
        if (c) {
            match (c) {
                .TYPE(t) => { return t; },
                .VOID => { return fail(p.span, fmt("'{}' has no type assigned yet", S(name))); },
                default => { return fail(p.span, fmt("'{}' is a value, not a type", S(name))); },
            }
        }
    }
    // otherwise a declared type: the primary decl of a struct, enum or trait, with its generic args
    val ns = this.env_at(e).ns;
    var f: found? = null;
    if (p.segs.len == 1) {
        f = this.lookup(ns, p.segs.at(0).name);
    } else {
        f = this.lookup_path_ns(ns, p);
    }
    val last = p.last();
    match (f ?? return this.unknown(p.span, "type", ns, p, false)) {
        .DECLS(l) => {
            var primary: u32? = null;
            for (d&) in this.list(l).items() {
                var is_type = false;
                match (this.item_of(*d).kind) {
                    .STRUCT(s) => { is_type = s.spec == null; },
                    .ENUM(x) => { is_type = true; },
                    .TRAIT(n, fs) => { is_type = true; },
                    .ALIAS(n, t) => { is_type = true; },
                    default => {},
                }
                if (is_type) {
                    primary = *d;
                    break;
                }
            }
            val d = primary ?? return fail(p.span, fmt("'{}' isn't a type", S(last)));
            try this.visible(d, p.span);
            if (this.opts.lsp) {
                this.lsp_decl_use(d, last, p.span, this.lsp_type_label(d, last));
            }
            val generic = this.item_of(d).generics.len > 0;
            val given = &p.segs.at(p.segs.len - 1).args;
            if (!generic && *given != null) {
                return fail(p.span, fmt("'{}' isn't generic", S(last)));
            }
            // another name: its type, resolved where it's declared (once, unless it's generic: then
            // with the arguments given here)
            match (this.item_of(d).kind) {
                .ALIAS(n, t&) => {
                    val have = this.aliases.get(d);
                    if (have) {
                        return *have;
                    }
                    var binds: std::vec<gbind> = {};
                    if (generic) {
                        var none: std::vec<garg> = {};
                        var gargs: std::vec<gval> = {};
                        if (*given) {
                            gargs = try this.gargs_for(d, &(*given).value, e, p.span);
                        } else {
                            gargs = try this.gargs_for(d, &none, e, p.span);
                        }
                        val gps = &this.item_of(d).generics;
                        for (i) in 0..gps.len {
                            val gp = gparam_of(gps.at(i));
                            put(&binds, { name: gps.at(i).name, g: copy *gargs.at(i), ty: param_ty(&gp) });
                        }
                    }
                    val ae = this.new_env({ ns: this.decls.at(@cast<usize>(d)).ns, generics: move binds });
                    if (!this.alias_resolving.add(d)) {
                        return fail(p.span, fmt("type '{}' is defined in terms of itself", S(last)));
                    }
                    val r = this.resolve_type(t, ae);
                    this.alias_resolving.remove(d);
                    val ty = try r;
                    // a type built right in the alias (type point3 = struct { ... }) takes its name
                    if (!generic && is_type_body(t)) {
                        var full = this.ns_path(this.decls.at(@cast<usize>(d)).ns, "::");
                        if (full.len() > 0) {
                            full.append("::");
                        }
                        full.append(last);
                        this.name_built(ty, this.intern(move full));
                    }
                    if (!generic) {
                        this.aliases.put(d, ty);
                    }
                    return ty;
                },
                default => {},
            }
            var args: std::vec<gval> = {};
            if (generic) {
                var none: std::vec<garg> = {};
                if (*given) {
                    args = try this.gargs_for(d, &(*given).value, e, p.span);
                } else {
                    args = try this.gargs_for(d, &none, e, p.span);
                }
            }
            var kind = 0;
            match (this.item_of(d).kind) {
                .STRUCT(s) => { kind = 1; },
                .ENUM(x) => { kind = 2; },
                default => {},
            }
            if (kind == 1) {
                return this.struct_inst(d, move args, p.span);
            }
            if (kind == 2) {
                return this.enum_inst(d, move args, p.span);
            }
            if (generic) {
                return fails(p.span, "generic traits can't be used as types yet");
            }
            return this.trait_union(d, p.span);
        },
        .NS(n) => { return fail(p.span, fmt("'{}' is a namespace, not a type", S(last))); },
    }
}

// the path of a namespace as a::b
attach fn ns_path(this: checker&, ns: u32, sep: str) -> std::string {
    var s: std::string = {};
    val p = &this.ns(ns).path;
    for (i) in 0..p.len {
        if (i > 0) {
            s.append(sep);
        }
        s.append(*p.at(i));
    }
    return s;
}

// The struct type for decl d with these generic args, made once per argument set. It uses the
// matching specialization if there is one, and records @owns. Fields resolve later.
attach fn struct_inst(this: checker&, d: u32, args: std::vec<gval>, span: span) -> compile_error!u32 {
    val key = this.inst_key(d, &args);
    val have = this.struct_ids.get(key.as_str());
    if (have) {
        return this.t.intern(tyk::STRUCT(*have));
    }
    // a generic Rust type: the instance bolt made for these types, when it has
    if (args.len > 0) {
        val rg = this.rust_generic_of(d);
        if (rg) {
            val made = try this.rust_type_instance(d, rg, &args, span);
            if (made) {
                return made;
            }
        }
    }
    val dns = this.dl(d).ns;
    // a C++ class template's instance clang says one of its specializations makes (an explicit
    // template <> struct S<void>, a partial S<T*>'s): the template's twin held by handle
    // (cppimport's special_twin), under the name written
    if (args.len > 0) {
        val tw = this.cpp_special_twin(d, &args);
        if (tw) {
            val t = try this.struct_inst(tw, copy args, span);
            val tid = *(this.struct_ids.get(this.inst_key(tw, &args).as_str()) ?? return t);
            var written = this.ns_path(dns, "::");
            if (written.len() > 0) {
                written.append("::");
            }
            written.append(this.decl_name(d));
            this.si(tid).name = this.shown_name(d, written.as_str(), &args);
            this.struct_ids.put(this.intern(move key), tid);
            return t;
        }
    }
    var sd: struct_decl* = null;
    match (this.item_of(d).kind) {
        .STRUCT(s&) => { sd = s; },
        default => { return fails(span, "not a struct"); },
    }
    val s = sd ?? return fails(span, "not a struct");
    var full = this.ns_path(dns, "::");
    if (full.len() > 0) {
        full.append("::");
    }
    full.append(s.name);
    var c_name = s.c_name ?? "";
    if (s.c_name == null) {
        var base = S("v_");
        base.append(replace_all(full.as_str(), "::", "__").as_str());
        c_name = this.fresh_c_name(base.as_str());
    }
    val name = this.inst_name(full.as_str(), &args);
    var pick = try this.pick_specialization(d, &args);
    val use_decl = pick.decl;
    val env = this.inst_env(dns, this.gparams_of(use_decl), &pick.binds);
    val id = @cast<u32>(this.structs.len);
    put(&this.structs, bx<struct_info>({ decl: use_decl, family: d, args: move args, env: env, name: name, c_name: c_name }));
    this.struct_ids.put(this.intern(move key), id);
    // (its name leaves out args equal to their defaults, worked out once it's known, so a default
    // that names this instance finds it)
    this.si(id).name = this.shown_name(d, full.as_str(), &this.si(id).args);
    // a header struct C aligns past its fields with Volt's own offsets (an aligned attribute): that
    // alignment, as @align gives one (cimport's lay_out_partial)
    if (s.c_name != null && s.c_offsets == null && !s.c_partial && !s.c_union && s.c_align > 0) {
        this.si(id).align = s.c_align;
    }
    // @attributes([@align(n)]): every value of the struct starts at a multiple of n (struct_fields
    // checks that n is at least what its fields need)
    for (a&) in this.item_of(use_decl).attrs.items() {
        match (a.kind) {
            .BUILTIN(n, g, args) => {
                if (n != "align" || args == null || args.value.len == 0) {
                    continue;
                }
                val e = this.garg_value(args.value.at(0)) catch |x| {
                    return fails(a.span, "@align on a struct takes a constant: @align(32)");
                };
                val v = this.const_int(e, env) catch |x| {
                    return fails(a.span, "@align on a struct takes a constant: @align(32)");
                };
                if (v < 1 || v > 4096 || (v & (v - 1)) != 0) {
                    var shown = S("@align(");
                    if (v < 0) {
                        shown.push('-');
                        shown.append_uint(@cast<u64>(0 - v));
                    } else {
                        shown.append_uint(@cast<u64>(v));
                    }
                    shown.append("): a struct's alignment is a power of two from 1 to 4096");
                    return fail(a.span, move shown);
                }
                this.si(id).align = @cast<u64>(v);
            },
            default => {},
        }
    }
    // @attributes([@owns("ptr")]): the struct owns what field `ptr: T*` points at (like std's box):
    // it's used like that T&, and deleting it deletes the T first. Nothing here knows std
    for (a&) in this.item_of(use_decl).attrs.items() {
        match (a.kind) {
            .BUILTIN(n, g, x) => {
                if (n != "owns") {
                    continue;
                }
                val fname = attr_str(a);
                var fd: field* = null;
                match (this.item_of(use_decl).kind) {
                    .STRUCT(u) => {
                        for (f&) in u.fields.items() {
                            if (fname != null && f.name == (fname ?? "")) {
                                fd = f;
                            }
                        }
                    },
                    default => {},
                }
                val f = fd ?? return fails(a.span, "@owns names a field of this struct: @owns(\"ptr\")");
                val fty = try this.resolve_type(&f.ty, env);
                var inner: u32? = null;
                match (*this.t.get(fty)) {
                    .REF(x) => { inner = x; },
                    .PTR(x) => { inner = x; },
                    default => {},
                }
                this.si(id).owns_field = f.name;
                this.si(id).owns_ty = inner ?? return fails(f.span, "an @owns field has to be a pointer (T*)");
                // box<T> with the default allocator is just its pointer, which a live box never has
                // null: T? can be the box itself, null meaning none (like Rust's Option<Box<T>>)
                var niche = true;
                var at: u32 = 0;
                var i: u32 = 0;
                match (this.item_of(use_decl).kind) {
                    .STRUCT(u) => {
                        for (g&) in u.fields.items() {
                            if (g.name == f.name) {
                                at = i;
                            } else {
                                val gt = try this.resolve_type(&g.ty, env);
                                if (!(try this.takes_no_space(gt, g.span))) {
                                    niche = false;
                                }
                            }
                            i += 1;
                        }
                    },
                    default => {},
                }
                if (niche) {
                    this.si(id).niche = at;
                }
                break;
            },
            default => {},
        }
    }
    return this.t.intern(tyk::STRUCT(id));
}

fn replace_all(s: str, from: str, to: str) -> std::string {
    var out: std::string = {};
    var i: usize = 0;
    while (i < s.len) {
        if (i + from.len <= s.len && s[i..i + from.len] == from) {
            out.append(to);
            i += from.len;
        } else {
            out.push(s[i]);
            i += 1;
        }
    }
    return out;
}

// pick_specialization's answer: the decl to instantiate and its own generic args
struct picked {
    decl: u32;
    binds: std::vec<gval>;
}

// a partial specialization (struct holder<T&>) whose pattern matches these args, if any
attach fn pick_specialization(this: checker&, primary: u32, args: std::vec<gval>&) -> compile_error!picked {
    val name = this.decl_name(primary);
    val ns = this.dl(primary).ns;
    val cands = this.named(&this.ns(ns).names, name);
    for (d&) in cands.items() {
        var pats: std::vec<garg>* = null;
        match (this.item_of(*d).kind) {
            .STRUCT(s&) => {
                if (s.spec) {
                    pats = &s.spec;
                }
            },
            default => {},
        }
        val ps = pats ?? continue;
        if (ps.len != args.len) {
            continue;
        }
        // bind the specialization's own generic params by matching its pattern against the args
        val gps = this.gparams_of(*d);
        var binds: std::vec<gval?> = {};
        for (i) in 0..gps.len {
            put(&binds, null);
        }
        for (i) in 0..ps.len {
            val pat = ps.at(i);
            match (*args.at(i)) {
                .TY(at) => {
                    match (*pat) {
                        .TYPE(t&) => { this.infer(t, at, gps, &binds, ns); },
                        default => {},
                    }
                },
                .INT(v) => {
                    match (*pat) {
                        .EXPR(x) => {
                            match (x.kind) {
                                .PATH(pp) => {
                                    if (pp.is_single()) {
                                        val j = gparam_index(gps, pp.segs.at(0).name);
                                        if (j) {
                                            *binds.at(j) = gval::INT(v);
                                        }
                                    }
                                },
                                default => {},
                            }
                        },
                        default => {},
                    }
                },
                default => {},
            }
        }
        if (!all_bound(&binds)) {
            continue;
        }
        // then the pattern, with those bindings, has to give back exactly the args
        val env = this.partial_env(ns, gps, &binds);
        var ok = true;
        for (i) in 0..ps.len {
            val pat = ps.at(i);
            var got: gval? = null;
            match (*args.at(i)) {
                .TY(t) => {
                    val r = this.garg_type_env(pat, env) catch |x| {
                        ok = false;
                        break;
                    };
                    got = gval::TY(r);
                },
                .INT(v) => {
                    match (*pat) {
                        .EXPR(x&) => {
                            val r = this.const_int(x, env) catch |y| {
                                ok = false;
                                break;
                            };
                            got = gval::INT(r);
                        },
                        default => {},
                    }
                },
                default => {},
            }
            if (got == null || !this.gval_eq(got ?? gval::INT(0), *args.at(i))) {
                ok = false;
                break;
            }
        }
        if (ok) {
            return { decl: *d, binds: unwrap_binds(&binds) };
        }
    }
    return { decl: primary, binds: copy *args };
}

fn all_bound(binds: std::vec<gval?>&) -> bool {
    for (b&) in binds.items() {
        if (*b == null) {
            return false;
        }
    }
    return true;
}

fn unwrap_binds(binds: std::vec<gval?>&) -> std::vec<gval> {
    var out: std::vec<gval> = {};
    for (b&) in binds.items() {
        put(&out, *b ?? gval::INT(0));
    }
    return out;
}

// a struct instance's fields, resolved on first use; fails if the struct contains itself by value
// whether a value of t is zero bytes (an empty struct, like the default allocator)
attach fn takes_no_space(this: checker&, t: u32, span: span) -> compile_error!bool {
    var parts: std::vec<u32> = {};
    match (*this.t.get(t)) {
        .VOID => { return true; },
        .ARRAY(e, n) => {
            if (n == 0) {
                return true;
            }
            put(&parts, e);
        },
        .TUPLE(ts, names) => { parts = copy ts; },
        .STRUCT(s) => {
            if (this.header_struct(s)) {
                return false;
            }
            for (f&) in (try this.struct_fields(s, span)).items() {
                put(&parts, f.ty);
            }
        },
        default => { return false; },
    }
    for (p) in parts.items() {
        if (!(try this.takes_no_space(p, span))) {
            return false;
        }
    }
    return true;
}

// the field whose null marks an optional of t empty: an @owns struct's pointer, when that's all it
// holds (box<T> with the default allocator)
attach fn niche_field(this: checker&, t: u32) -> u32? {
    match (*this.t.get(t)) {
        .STRUCT(s) => { return this.si(s).niche; },
        default => { return null; },
    }
}

// is an optional of t just t (a pointer-like one, or an owning struct's pointer), with none as null?
attach fn niche(this: checker&, t: u32) -> bool {
    return this.t.is_niche(t) || this.niche_field(t) != null;
}

attach fn struct_fields(this: checker&, sid: u32, span: span) -> compile_error!(std::vec<field_info>&) {
    val info = this.si(sid);
    if (info.has_fields) {
        return &info.fields;
    }
    if (info.resolving) {
        return fail(span, fmt("struct '{}' contains itself (use a reference or box)", S(info.name)));
    }
    info.resolving = true;
    val decl = info.decl;
    val env = info.env;
    var out: std::vec<field_info> = {};
    match (this.item_of(decl).kind) {
        .STRUCT(s) => {
            for (f&) in s.fields.items() {
                val t = try this.resolve_type(&f.ty, env);
                var fb: expr* = null;
                if (f.fallback) {
                    fb = &f.fallback;
                }
                put(&out, { name: f.name, ty: t, fallback: fb, vis: f.vis });
            }
        },
        default => {},
    }
    val again = this.si(sid);
    again.fields = move out;
    again.has_fields = true;
    again.resolving = false;
    if (again.align > 0) {
        try this.check_align(sid);
    }
    return &this.si(sid).fields;
}

// @align(n) on struct sid can't be below what its fields need: C would ignore it, and the layout
// would no longer be C's
attach fn check_align(this: checker&, sid: u32) -> compile_error!void {
    val want = this.si(sid).align;
    var need: u64 = 1;
    val fs = copy this.si(sid).fields;
    for (f&) in fs.items() {
        val l = this.layout_opt(f.ty, {}) ?? continue;
        if (l.align > need) {
            need = l.align;
        }
    }
    if (want >= need) {
        return;
    }
    var sp: span = {};
    for (a&) in this.item_of(this.si(sid).decl).attrs.items() {
        if (attr_named(a, "align")) {
            sp = a.span;
        }
    }
    return fail(sp, fmt2("@align({}) is below what this struct's fields need: they're aligned to {} bytes", unum(want), unum(need)));
}

// an env in ns with params bound to args, pairwise
attach fn inst_env(this: checker&, ns: u32, params: std::vec<gparam>&, args: std::vec<gval>&) -> u32 {
    var e: env = { ns: ns };
    for (i) in 0..params.len {
        if (i < args.len) {
            put(&e.generics, { name: params.at(i).name, g: *args.at(i), ty: param_ty(params.at(i)) });
        }
    }
    return this.new_env(move e);
}

// ---------- constants ----------

// Integer constant expressions: literals, arithmetic, generic consts.
attach fn const_int(this: checker&, e: expr&, env: u32) -> compile_error!i128 {
    val v = this.const_int_simple(e, env) catch |first| {
        return this.const_int_ct(e, env, copy first);
    };
    return v;
}

// const_int's fallback, the comptime interpreter. Only its overflow and compile-time errors are
// reported; any other failure reports first, the simple path's error
attach fn const_int_ct(this: checker&, e: expr&, env: u32, first: compile_error) -> compile_error!i128 {
    var v = this.ct_eval_in(env, e, null) catch |d| {
        val m = err_msg(&d);
        if (contains(m, "compile") || contains(m, "overflow")) {
            return copy d;
        }
        return first;
    };
    this.c_enum_ct(&v);
    match (v) {
        .INT(x, t) => { return x; },
        default => { return fails(e.span, "expected an integer"); },
    }
}

// const_int without the comptime interpreter: literals, integer operators, generic ints and
// immutable globals
attach fn const_int_simple(this: checker&, e: expr&, env: u32) -> compile_error!i128 {
    match (e.kind) {
        .INT(v) => { return @cast<i128>(v); },
        .CHAR(v) => { return @cast<i128>(v); },
        .UNARY(op, x) => {
            match (op) {
                .NEG => { return 0 -% (try this.const_int_simple(x, env)); },
                .BITNOT => { return ~(try this.const_int_simple(x, env)); },
                default => {},
            }
        },
        .BINARY(op, a, b) => {
            val x = try this.const_int_simple(a, env);
            val y = try this.const_int_simple(b, env);
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
                .SHL => { r = shl_i128(x, y); },
                .SHR => { r = shr_i128(x, y); },
                default => { return fails(e.span, "expected a constant integer expression"); },
            }
            return r ?? return fails(e.span, "constant overflow or division by zero");
        },
        .PATH(p) => {
            if (p.is_single()) {
                val name = p.segs.at(0).name;
                val g = this.env_generic(env, name);
                if (g) {
                    match (g) {
                        .INT(v) => { return v; },
                        default => {},
                    }
                }
                val f = this.lookup(this.env_at(env).ns, name);
                if (f) {
                    match (f) {
                        .DECLS(l) => {
                            if (this.list(l).len == 1) {
                                match (this.item_of(*this.list(l).at(0)).kind) {
                                    .GLOBAL(gl) => {
                                        if (!gl.mutable && gl.init != null) {
                                            return this.const_int_simple(&gl.init.value, env);
                                        }
                                    },
                                    default => {},
                                }
                            }
                        },
                        default => {},
                    }
                }
            }
        },
        default => {},
    }
    return fails(e.span, "expected a constant integer expression");
}

// a checked array length: C objects can't be bigger than PTRDIFF_MAX
fn array_len(n: i128, sp: span) -> compile_error!u64 {
    if (n < 0) {
        return fails(sp, "array length can't be negative");
    }
    if (n > 9223372036854775807) {
        return fail(sp, fmt("array length {} is too big", num(n)));
    }
    return @cast<u64>(n);
}

// ---------- functions ----------

// an export fn's C symbol: its name; an attach fn's after its struct's (counter_add); an instance
// of a generic one with its arguments after it (sum_i32)
attach fn export_c_name(this: checker&, d: u32, name: str, is_attach: bool, params: std::vec<param_info>&, args: std::vec<gval>&) -> str {
    val pkg = this.pkg_of(d) ?? "";
    var n: std::string = {};
    if (is_attach && params.len > 0) {
        var t = params.at(0).ty;
        match (*this.t.get(t)) {
            .REF(x) => { t = x; },
            .PTR(x) => { t = x; },
            default => {},
        }
        n = ident_of(strip_pkg(this.ty_name(t).as_str(), pkg));
        n.push('_');
    }
    n.append(name);
    for (a&) in args.items() {
        var g: std::string = {};
        this.gval_name(&g, *a);
        n.push('_');
        n.append(ident_of(strip_pkg(g.as_str(), pkg)).as_str());
    }
    // a name C or C++ can't declare (int, typeof, delete) is exported with a _, so a header can name it
    if (c_word(n.as_str())) {
        n.push('_');
    }
    return this.intern(move n);
}

// a type's name without package pkg's own namespace (mathlib::vec2 is vec2 in mathlib)
fn strip_pkg(name: str, pkg: str) -> str {
    if (pkg.len > 0 && name.len > pkg.len + 2 && name[0..pkg.len] == pkg && name[pkg.len..pkg.len + 2] == "::") {
        return name[pkg.len + 2..name.len];
    }
    return name;
}

// The fn instance for decl d with these generic args, made once per argument set: resolves the
// signature, picks the C name, claims extern/export C symbols and adds an empty ir fn. Doesn't
// check the body; use_fn queues that once the instance is called.
attach fn fn_inst(this: checker&, d: u32, args: std::vec<gval>, span: span) -> compile_error!u32 {
    val key = this.inst_key(d, &args);
    val have = this.fn_ids.get(key.as_str());
    if (have) {
        return *have;
    }
    // a generic Rust fn: the instance bolt made for these types, when it has
    if (args.len > 0) {
        val rg = this.rust_generic_of(d);
        if (rg) {
            val made = try this.rust_instance(d, rg, &args, span);
            if (made) {
                return made;
            }
        }
    }
    val it = this.item_of(d);
    val dns = this.dl(d).ns;
    val f = this.fn_decl_of(d) ?? return fails(span, "not a function");
    val gps = this.fn_generics(d);
    if (gps.len != args.len) {
        return fail(span, fmt2("'{}' needs its generic arguments: {}<...>", S(f.name), S(f.name)));
    }
    // a template that recurses into ever new instances of itself would never stop
    val fam = this.family_count.get(d);
    var count: u32 = 0;
    if (fam) {
        count = *fam;
    }
    if (count > 500) {
        return fail(span, fmt("'{}' was instantiated over 500 times; is a generic recursing forever?", S(f.name)));
    }
    val env = this.inst_env(dns, gps, &args);
    // the signature: `this` takes its type from the receiver pattern; a pack param (xs: T...) has the
    // tuple type its pack resolves to
    var params: std::vec<param_info> = {};
    var pack = false;
    for (p&) in f.params.items() {
        if (p.name == "this") {
            if (p.is_static) {
                continue;
            }
            var pat: ty* = null;
            match (this.recv_of(d)) {
                .VAL(x) => { pat = x; },
                default => {},
            }
            val t = try this.resolve_type(pat ?? return fails(p.span, "this needs a type here: this: T or this: T&"), env);
            // an operator nothing could call: operators are looked up on structs and enums only
            if (is_operator_fn(f.name) && !this.has_ops(t)) {
                return fail(p.span, fmt("an operator's this is a struct or an enum (or a reference to one), not {}", this.ty_name(t)));
            }
            put(&params, { name: "this", ty: t, mutable: p.mutable, fallback: null, is_comptime: false });
            continue;
        }
        if (p.ty == null) {
            return fails(p.span, "parameter needs a type");
        }
        var t: u32 = VOID;
        match (p.ty.value.kind) {
            .PACK(inner) => {
                pack = true;
                t = try this.resolve_type(inner, env);
            },
            default => { t = try this.resolve_type(&p.ty.value, env); },
        }
        var fb: expr* = null;
        if (p.fallback) {
            fb = &p.fallback;
        }
        put(&params, { name: p.name, ty: t, mutable: p.mutable, fallback: fb, is_comptime: p.is_comptime });
    }
    var ret = VOID;
    if (f.ret) {
        ret = try this.resolve_type(&f.ret, env);
    }
    val intrinsic = intrinsic_of(it);
    val path = this.ns_path(dns, "__");
    var c_name = "";
    val intr = intrinsic ?? "";
    if (intrinsic != null && starts_with(intr, "volt_")) {
        c_name = intr; // a prelude function
    } else if (f.extern_abi != null && args.len > 0 && f.body != null && !f.is_export) {
        // a generic extern fn's instance (a callback per type): C can't name it, so each gets
        // its own symbol
        var n = S("v_");
        if (path.len() > 0) {
            n.append(path.as_str());
            n.append("__");
        }
        n.append(c_word(f.name));
        c_name = this.fresh_c_name(n.as_str());
    } else if (f.extern_abi != null && (f.extern_abi ?? "") == "C" && !f.is_export) {
        // declared under our own name, bound to the real symbol, so it never clashes with a C
        // header's prototype of the same function; a package's carries its namespace too, so std's
        // own externs never meet a program's extern of the same function with another signature
        var n = S("volt_ext_");
        if (this.pkg_of(d) != null && path.len() > 0) {
            n.append(path.as_str());
            n.append("__");
        }
        n.append(f.name);
        c_name = this.intern(move n);
    } else if (f.is_export && f.c_name == null) {
        c_name = this.export_c_name(d, f.name, f.is_attach, &params, &args);
        this.used_c_names.put(c_name, 1); // fixed: a generated name goes around it
    } else if (f.extern_abi != null || f.is_export) {
        c_name = f.c_name ?? f.name;
        this.used_c_names.put(c_name, 1);
    } else if (f.name == "main" && path.len() == 0 && args.len == 0) {
        c_name = "v_main";
    } else if (this.pkg_of(d) != null && args.len == 0) {
        // a package fn gets the same name in every C unit, so a precompiled package links
        var sig: std::string = {};
        for (i) in 0..params.len {
            if (i > 0) {
                sig.push(',');
            }
            this.put_ty(&sig, params.at(i).ty);
        }
        if (params.len > 0) {
            sig.push(',');
        }
        this.put_ty(&sig, ret);
        var n = S("vp_");
        n.append(path.as_str());
        n.append("__");
        n.append(c_word(f.name));
        n.push('_');
        n.append(hex8(fnv32(sig.as_str())).as_str());
        c_name = this.intern(move n);
        this.used_c_names.put(c_name, 1);
    } else {
        var n = S("v_");
        if (path.len() > 0) {
            n.append(path.as_str());
            n.append("__");
        }
        n.append(c_word(f.name));
        c_name = this.fresh_c_name(n.as_str());
    }
    val name = this.shown_name(d, f.name, &args);
    if (intrinsic == null && f.body == null && f.extern_abi == null) {
        return fail(it.span, fmt("function '{}' needs a body (only extern fns can leave it off)", S(f.name)));
    }
    if (f.is_async && f.body == null) {
        return fail(it.span, fmt("'{}' is async, so it needs a body: Volt runs an async fn's frame, and a C function has none", S(f.name)));
    }
    if ((f.extern_abi != null && !(args.len > 0 && f.body != null)) || f.is_export) {
        // C has no overloading: one symbol, one signature
        var sig_ps: std::vec<u32> = {};
        for (p&) in params.items() {
            put(&sig_ps, p.ty);
        }
        val other = this.c_symbols.get(f.name);
        if (other) {
            val od = other.decl;
            var other_export = false;
            val of = this.fn_decl_of(od);
            if (of) {
                other_export = of.is_export;
            }
            val differs = !same_list(&other.params, &sig_ps) || other.ret != ret;
            val header_diff = this.is_header_fn(od) || this.is_header_fn(d);
            // two externs under different C names (different packages) are two C declarations of one symbol
            if (od != d && (f.is_export || other_export || (differs && !header_diff && other.c_name == c_name))) {
                return fail(it.span, fmt("C function '{}' is declared twice; exported and extern names can't be overloaded", S(c_name)));
            }
        }
        this.c_symbols.put(f.name, { decl: d, params: move sig_ps, ret: ret, c_name: c_name });
    }
    val idx = @cast<u32>(this.fns.len);
    // its IR function, with the parameters as locals (a declaration needs their types)
    var irf: ir_fn = { name: c_name, params: {}, ret: ret, link: linkage::STATIC, c_varargs: f.c_varargs, noreturn: ret == NEVER };
    if (starts_with(c_name, "volt_ext_")) {
        irf.real_name = f.name;
    }
    if (f.is_async) {
        irf.ret = this.t.intern(tyk::FRAME(idx)); // it builds the frame; the helpers run it
    }
    irf.from_header = this.is_header_fn(d);
    irf.prelude = intrinsic != null && starts_with(intr, "volt_");
    irf.origin = it.span;
    irf.about = name;
    irf.attrs = this.fn_attrs_of(&it.attrs);
    for (i) in 0..params.len {
        val p = params.at(i);
        if (p.is_comptime || p.ty == VOID) {
            continue;
        }
        put(&irf.locals, { name: p.name, ty: p.ty });
        put(&irf.params, @cast<u32>(irf.locals.len - 1));
    }
    put(&this.ir.fns, bx(move irf));
    val ir_idx = @cast<u32>(this.ir.fns.len - 1);
    put(&this.fns, bx<fn_inst>({ decl: d, name: name, pack: pack, env: env, c_name: c_name, params: move params, ret: ret, c_varargs: f.c_varargs, intrinsic: intrinsic, ir: ir_idx, used_at: span, used_in: this.gen_fn_idx }));
    put(&this.used, false);
    this.fn_ids.put(this.intern(move key), idx);
    this.family_count.put(d, count + 1);
    return idx;
}

// A C++ template's Volt generic is made once per type, so a val's &k would share the var's body,
// which C++ may write through. Called with a std::string that can't change for a std::string&
// parameter (bit i of mask), it gets an instance of its own, whose body reads those strings as
// read-only: of S& / const S& it runs const S&, and an S&-only one writes through the parameter,
// which the caller's lend check refuses (cpp_text_template)
attach fn ro_text_inst(this: checker&, inst: u32, off: usize, pre: std::vec<tval?>&) -> u32 {
    val f = this.fi(inst);
    if (f.env == 0 || this.env_at(f.env).generics.len == 0 || !this.in_cpp_import(this.dl(f.decl).ns)) {
        return inst;
    }
    var mask: u64 = 0;
    for (i) in 0..pre.len {
        val p = i + off;
        if (p >= f.params.len || p >= 64) {
            break;
        }
        val v = *pre.at(i);
        if (v) {
            val pt = f.params.at(p).ty;
            if ((v.ro & 1) != 0 && this.t.ref_inner(pt) != null && this.text_bound(pt)) {
                mask = mask | (@cast<u64>(1) << @cast<u32>(p));
            }
        }
    }
    if (mask == 0) {
        return inst;
    }
    val key = fmt2("ro{}|{}", unum(@cast<u64>(inst)), unum(mask));
    val have = this.fn_ids.get(key.as_str());
    if (have) {
        return *have;
    }
    val src = this.ir.fn_at(f.ir);
    var irf: ir_fn = { name: this.fresh_c_name(f.c_name), params: {}, ret: src.ret, link: linkage::STATIC, c_varargs: src.c_varargs, noreturn: src.noreturn };
    irf.from_header = src.from_header;
    irf.origin = src.origin;
    irf.about = src.about;
    irf.attrs = copy src.attrs;
    for (i) in 0..f.params.len {
        val p = f.params.at(i);
        if (p.is_comptime || p.ty == VOID) {
            continue;
        }
        put(&irf.locals, { name: p.name, ty: p.ty });
        put(&irf.params, @cast<u32>(irf.locals.len - 1));
    }
    put(&this.ir.fns, bx(move irf));
    val ir_idx = @cast<u32>(this.ir.fns.len - 1);
    val idx = @cast<u32>(this.fns.len);
    put(&this.fns, bx<fn_inst>({ decl: f.decl, name: f.name, pack: f.pack, env: f.env, c_name: this.ir.fn_at(ir_idx).name, params: copy f.params, ret: f.ret, c_varargs: f.c_varargs, intrinsic: f.intrinsic, ir: ir_idx, used_at: f.used_at, used_in: f.used_in, ro_texts: mask }));
    put(&this.used, false);
    this.fn_ids.put(this.intern(move key), idx);
    return idx;
}

fn same_list(a: std::vec<u32>&, b: std::vec<u32>&) -> bool {
    if (a.len != b.len) {
        return false;
    }
    for (i) in 0..a.len {
        if (*a.at(i) != *b.at(i)) {
            return false;
        }
    }
    return true;
}

// declared by an imported C header (the #include declares it)
attach fn is_header_fn(this: checker&, d: u32) -> bool {
    val f = this.fn_decl_of(d) ?? return false;
    return f.extern_abi != null && (f.extern_abi ?? "") == C_HEADER;
}

// Where a fn's definition lives. Package fns that are the same in every program (not generic,
// not async, no trait union in the signature) can come from the package's prebuilt library.
attach fn fn_linkage(this: checker&, idx: u32) -> linkage {
    val d = this.fi(idx).decl;
    val f = this.fn_decl_of(d) ?? return linkage::STATIC;
    val pkg = this.pkg_of(d);
    val lib = pkg != null && this.opts.lib != null && (this.opts.lib ?? "") == (pkg ?? "");
    var linked = false;
    for (l&) in this.opts.linked.items() {
        if (pkg != null && *l == (pkg ?? "")) {
            linked = true;
        }
    }
    if (f.extern_abi != null || f.is_export) {
        // a linked package's export fn is its library's: defined there, declared here
        if (f.is_export && f.body != null && linked && !lib) {
            return linkage::EXTERNAL;
        }
        return linkage::EXPORTED;
    }
    if (pkg == null) {
        return linkage::STATIC;
    }
    // a specialization (fn f<i64>) is built where it's used, like the template it specializes: a
    // library has nothing calling it
    if (!(lib || linked) || f.body == null || f.is_async || f.is_comptime || this.fi(idx).intrinsic != null || this.fn_generics(d).len > 0 || f.spec != null) {
        return linkage::STATIC;
    }
    var seen: idset = {};
    for (p&) in this.fi(idx).params.items() {
        if (this.has_union(p.ty, &seen)) {
            return linkage::STATIC;
        }
    }
    if (this.has_union(this.fi(idx).ret, &seen)) {
        return linkage::STATIC;
    }
    if (lib) {
        return linkage::EXPORTED;
    }
    return linkage::EXTERNAL;
}

// does a value of this type hold a trait union somewhere?
attach fn has_union(this: checker&, t: u32, seen: idset&) -> bool {
    return this.holds_union(t, null, seen);
}

// does a value of this type hold trait union `want` (any, when none) somewhere?
attach fn holds_union(this: checker&, t: u32, want: u32?, seen: idset&) -> bool {
    if (!seen.add(t)) {
        return false;
    }
    var inner: std::vec<u32> = {};
    match (*this.t.get(t)) {
        .TRAIT_UNION(u) => {
            if (want == null || (want ?? 0) == u) {
                return true;
            }
            inner = copy this.ui(u).members; // (laid out in it)
        },
        .REF(x) => { put(&inner, x); },
        .PTR(x) => { put(&inner, x); },
        .OPT(x) => { put(&inner, x); },
        .ARRAY(x, n) => { put(&inner, x); },
        .SLICE(x) => { put(&inner, x); },
        .RANGE(x) => { put(&inner, x); },
        .TUPLE(ts, names) => { inner = copy ts; },
        .ERR_UNION(e, x) => {
            put(&inner, e);
            put(&inner, x);
        },
        .FN_VAL(ps, r) => {
            inner = copy ps;
            put(&inner, r);
        },
        .FN_PTR(ps, r, va) => {
            inner = copy ps;
            put(&inner, r);
        },
        // a struct that can't be resolved reports its own error where it's used; here it just
        // counts as union-free
        .STRUCT(s) => {
            val fs = this.struct_fields(s, {}) catch |e| { return false; };
            for (f&) in fs.items() {
                put(&inner, f.ty);
            }
        },
        .ENUM(e) => {
            val ps = this.enum_payloads(e, {}) catch |x| { return false; };
            for (p&) in ps.items() {
                if (*p) {
                    put(&inner, *p ?? 0);
                }
            }
        },
        default => {},
    }
    for (x&) in inner.items() {
        if (this.holds_union(*x, want, seen)) {
            return true;
        }
    }
    return false;
}

// ---------- globals ----------

// A global's place, type and mutability. The first use checks its initializer (which must be
// constant) and adds it to the IR's globals.
attach fn global(this: checker&, d: u32, span: span) -> compile_error!global_ref {
    val have = this.global_c.get(d);
    if (have) {
        return *have;
    }
    var gl: let_stmt* = null;
    match (this.item_of(d).kind) {
        .GLOBAL(l&) => { gl = l; },
        default => {},
    }
    val l = gl ?? return fails(span, "not a global");
    var name = "";
    match (l.pat.kind) {
        .BIND(n) => { name = n; },
        default => {},
    }
    val ns = this.dl(d).ns;
    val genv = this.new_env({ ns: ns });
    if (l.c_name != null && l.ty != null) {
        // defined by an imported header
        val t = try this.resolve_type(&l.ty.value, genv);
        put(&this.ir.globals, { name: l.c_name ?? "", ty: t, init: null, mutable: l.mutable, link: linkage::EXTERNAL, header: true });
        val g: global_ref = { c: this.ir.node(ir_kind::GLOBAL(@cast<u32>(this.ir.globals.len - 1)), t), ty: t, mutable: l.mutable };
        this.global_c.put(d, g);
        return g;
    }
    var full = this.ns_path(ns, "__");
    if (full.len() > 0) {
        full.append("__");
    }
    full.append(name);
    val pkg = this.pkg_of(d);
    var c = "";
    if (pkg) {
        // stable across C units, like package fns
        var n = S("vpg_");
        n.append(full.as_str());
        c = this.intern(move n);
        this.used_c_names.put(c, 1);
    } else {
        var n = S("vg_");
        n.append(full.as_str());
        c = this.fresh_c_name(n.as_str());
    }
    // check the initializer in an empty function context: it must be a constant
    var saved = new_cx(VOID, genv, 0);
    swap(&this.cx, &saved);
    val r = this.global_init(l, span);
    swap(&this.cx, &saved);
    val gv = try r;
    var link = linkage::STATIC;
    var init: u32? = gv.c;
    if (pkg) {
        var linked = false;
        for (x&) in this.opts.linked.items() {
            if (*x == (pkg)) {
                linked = true;
            }
        }
        if (linked) {
            link = linkage::EXTERNAL; // defined in the package's library
            init = null;
        } else if (this.opts.lib != null && (this.opts.lib ?? "") == (pkg)) {
            link = linkage::EXPORTED;
        }
    }
    var tls = false;
    var section: str? = null;
    for (a&) in this.item_of(d).attrs.items() {
        tls = tls || attr_named(a, "thread_local");
        if (attr_named(a, "section")) {
            section = attr_str(a) ?? return fails(a.span, "@section takes the section's name: @section(\".data.table\")");
        }
    }
    // a global in a section is data the image carries (a vector table read before anything runs):
    // its initializer can't wait for a constructor (reported here once; the global still resolves,
    // so each use doesn't report it again)
    if (section != null && init != null && !this.const_data(init ?? 0)) {
        var e = fail(span, fmt("'{}' is in a section, so it's data the image holds as it is: its initializer has to be constants (numbers, literals, fn names, addresses of globals), not something run at startup", S(name)));
        put(&this.errors, err_diag(&e));
    }
    put(&this.ir.globals, { name: c, ty: gv.ty, init: init, mutable: l.mutable, link: link, origin: span, tls: tls, section: section, keep: section != null });
    val g: global_ref = { c: this.ir.node(ir_kind::GLOBAL(@cast<u32>(this.ir.globals.len - 1)), gv.ty), ty: gv.ty, mutable: l.mutable };
    this.global_c.put(d, g);
    return g;
}

// is IR node n a value the object file holds as it is: numbers, literals, a fn's address, and
// aggregates and arrays of them
attach fn const_data(this: checker&, n: u32) -> bool {
    match (this.ir.at(n).kind) {
        .INT(x) => { return true; },
        .FLOAT(x) => { return true; },
        .QUAD(x) => { return true; },
        .BOOL(x) => { return true; },
        .STR(x) => { return true; },
        .CSTR(x) => { return true; },
        .FN(f) => { return true; },
        .ZERO => { return true; },
        .NULLPTR => { return true; },
        .ADDR(p) => { return this.const_place(p); },
        .AGG(inits&) => {
            for (fi&) in inits.items() {
                if (!this.const_data(fi.value)) {
                    return false;
                }
            }
            return true;
        },
        .ARRAY_LIT(xs&) => {
            for (x&) in xs.items() {
                if (!this.const_data(*x)) {
                    return false;
                }
            }
            return true;
        },
        default => { return false; },
    }
}

// is IR node p a place whose address the object file can hold: a global, or a field or constant
// index of one
attach fn const_place(this: checker&, p: u32) -> bool {
    match (this.ir.at(p).kind) {
        .GLOBAL(g) => { return true; },
        .FIELD(b, i) => { return this.const_place(b); },
        .INDEX(b, i) => {
            match (this.ir.at(i).kind) {
                .INT(v) => { return this.const_place(b); },
                default => { return false; },
            }
        },
        default => { return false; },
    }
}

// A linked package with a global whose type holds a trait union is built from source instead: the
// union's layout comes from the types the program attaches, and the library's code that touches the
// global was built with the members the library saw. A warning names the global. So is one with an
// export fn whose signature holds one: the library defines that fn (fn_linkage's EXTERNAL), and its
// switch on the union's tags knows only the members the library saw.
// ponytail: the whole package loses its library; define just the global (and rebuild the fns whose
// bodies touch it) when a real package needs both.
// So is a linked package that uses one built from source (transitively): its library refers to the
// other's symbols, which the program now defines privately. A library build unlinks nothing: its
// references to the packages it links stay, and the program linking it decides. But the linked
// packages of an embedded VM's script are running (opts.running): nothing is rebuilt, and a trait
// union their globals hold takes no member from this one (running_union_globals).
attach fn unlink_union_globals(this: checker&) -> void {
    if (this.opts.lib != null && !this.opts.running) {
        return;
    }
    // the scan's global() calls are undone after it, and use_fn does nothing during it: a global or
    // fn it reaches (an untyped initializer naming another, or a fn value) gets its linkage when it's
    // really used, after the packages are settled
    val n0 = this.ir.globals.len;
    var gc0 = copy this.global_c;
    var gone: std::vec<str> = {};
    this.scanning = true;
    for (p&) in this.opts.linked.items() {
        val pkg = *p;
        if (has_name(&gone, pkg)) {
            continue; // linked twice
        }
        if (this.opts.running) {
            this.running_union_globals(pkg);
            continue;
        }
        val w = this.union_global(pkg, 0) ?? continue;
        var what = fmt("its global '{}' holds a trait union", S(w.name));
        if (w.is_fn) {
            what = fmt("its export fn '{}' takes or gives a trait union", S(w.name));
        }
        var d: diag = { span: w.span, msg: fmt2("{}'s library isn't used: {}", S(pkg), S(what.as_str())), warning: true };
        put(&d.notes, S("the union's layout depends on the types this program attaches, so the package is built from source"));
        put(&this.warnings, move d);
        put(&gone, pkg);
    }
    this.scanning = false;
    while (this.ir.globals.len > n0) {
        this.ir.globals.pop();
    }
    this.global_c = move gc0;
    // the packages that use one built from source. ponytail: "uses" is a path starting with its name
    // in the package's code (names_pkg), not resolved: a package named like another's module (fmt,
    // json) matches std's fmt::x too. A false match only costs that package its library (built from
    // source); resolve the paths if that bites
    var more = gone.len > 0;
    while (more) {
        more = false;
        for (p&) in this.opts.linked.items() {
            val pkg = *p;
            if (has_name(&gone, pkg)) {
                continue;
            }
            for (g&) in gone.items() {
                if (this.pkg_names(pkg, *g)) {
                    put(&this.warnings, { span: NO_SPAN, msg: fmt2("{}'s library isn't used: it uses {}, which is built from source", S(pkg), S(*g)), warning: true });
                    put(&gone, pkg);
                    more = true;
                    break;
                }
            }
        }
    }
    var i: usize = 0;
    while (i < this.opts.linked.len) {
        if (has_name(&gone, *this.opts.linked.at(i))) {
            this.opts.linked.remove(i);
        } else {
            i += 1;
        }
    }
}

// does one of package pkg's files name package other?
attach fn pkg_names(this: checker&, pkg: str, other: str) -> bool {
    for (fi) in 0..this.files.len {
        if ((this.pkg_of_file(@cast<u32>(fi)) ?? "") == pkg && names_pkg(this.files.at(fi).text, other)) {
            return true;
        }
    }
    return false;
}

// does the code start a path with package pkg (pkg::x, use pkg::{...})? Lexed, so comments and
// strings don't count; a file that doesn't lex (already reported) counts as naming it
fn names_pkg(text: str, pkg: str) -> bool {
    val toks = lex(text, 0) catch |e| { return true; };
    for (i) in 1..toks.len {
        var sep = false;
        match (toks.at(i).tok) {
            .PUNCT(p) => { sep = p == "::"; },
            default => {},
        }
        if (sep) {
            match (toks.at(i - 1).tok) {
                .IDENT(n) => {
                    if (n == pkg) {
                        return true;
                    }
                },
                default => {},
            }
        }
    }
    return false;
}

// the first global of package pkg (from decl `from` on) whose type holds a trait union, or export fn
// whose signature does (its library's code, fn_linkage's EXTERNAL, built for the union's members
// then)
attach fn union_global(this: checker&, pkg: str, from: u32) -> global_why? {
    for (di) in @cast<usize>(from)..this.decls.len {
        val d = @cast<u32>(di);
        if ((this.pkg_of(d) ?? "") != pkg) {
            continue;
        }
        match (this.item_of(d).kind) {
            .GLOBAL(l&) => {
                if (l.c_name != null) {
                    continue;
                }
                var name = "";
                match (l.pat.kind) {
                    .BIND(n) => { name = n; },
                    default => {},
                }
                // its declared type, else its initializer's, in the empty context global() uses (an
                // error is reported there)
                var saved = new_cx(VOID, this.new_env({ ns: this.dl(d).ns }), 0);
                swap(&this.cx, &saved);
                var ty: u32 = 0;
                if (l.ty) {
                    ty = this.decl_type(&l.ty, ptr_of(&l.init)) catch |e| {
                        swap(&this.cx, &saved);
                        continue;
                    };
                } else {
                    val gv = this.global_init(l, this.item_of(d).span) catch |e| {
                        swap(&this.cx, &saved);
                        continue;
                    };
                    ty = gv.ty;
                }
                swap(&this.cx, &saved);
                var seen: idset = {};
                if (this.has_union(ty, &seen)) {
                    return { name: name, span: this.item_of(d).span, decl: d, ty: ty };
                }
            },
            .FN(f&) => {
                if (!f.is_export || f.body == null || this.fn_generics(d).len > 0) {
                    continue;
                }
                val env = this.new_env({ ns: this.dl(d).ns });
                var saved = new_cx(VOID, env, 0);
                swap(&this.cx, &saved);
                val sig = this.export_sig(f, env);
                swap(&this.cx, &saved);
                val ty = sig ?? continue;
                var seen: idset = {};
                if (this.has_union(ty, &seen)) {
                    return { name: f.name, span: this.item_of(d).span, decl: d, ty: ty, is_fn: true };
                }
            },
            default => {},
        }
    }
    return null;
}

// an export fn's signature as a fn pointer type, or none when a type in it doesn't resolve (that's
// reported where the fn is checked)
attach fn export_sig(this: checker&, f: fn_decl&, env: u32) -> u32? {
    var ps: std::vec<u32> = {};
    for (p&) in f.params.items() {
        if (p.ty == null) {
            return null;
        }
        val t = this.resolve_type(&p.ty.value, env) catch |e| { return null; };
        put(&ps, t);
    }
    var ret = VOID;
    if (f.ret) {
        ret = this.resolve_type(&f.ret, env) catch |e| { return null; };
    }
    return this.t.intern(tyk::FN_PTR(move ps, ret, false));
}

struct global_why {
    name: str;
    span: span;
    decl: u32;
    ty: u32; // an export fn's: its signature, as a fn pointer
    is_fn: bool = false;
}

// why the trait union w holds can't take a member from a later load: "the global P::N holds T's
// union, laid out (and P's code built) for the types attached when P loaded"
fn union_why(w: global_why&, pkg: str, tr: str) -> std::string {
    var out = fmt3("the global {}::{} holds {}'s union", S(pkg), S(w.name), S(tr));
    if (w.is_fn) {
        out = fmt3("the export fn {}::{} takes or gives {}'s union", S(pkg), S(w.name), S(tr));
    }
    out.append(fmt2(", laid out (and {}'s code built) for the types attached when {} loaded", S(pkg), S(pkg)).as_str());
    return out;
}

// running linked package pkg (opts.running): an attach block of this package's for a trait whose union
// one of pkg's globals holds is an error naming the trait and the global. The global was laid out for
// the members its load saw, and pkg's code reading it switches on those alone: a new one could
// overflow it, or reach that switch's unreachable default
attach fn running_union_globals(this: checker&, pkg: str) -> void {
    val lib = this.opts.lib ?? return;
    val blocks = copy this.attach_blocks;
    // (a script attaching nothing changes no union: skip resolving pkg's export fns' types)
    var attaches = false;
    for (b&) in blocks.items() {
        if ((this.pkg_of(*b) ?? "") == lib && this.item_of(*b).generics.len == 0) {
            attaches = true;
        }
    }
    if (!attaches) {
        return;
    }
    var from: u32 = 0;
    loop {
        val w = this.union_global(pkg, from) ?? return;
        from = w.decl + 1;
        for (b&) in blocks.items() {
            if ((this.pkg_of(*b) ?? "") != lib || this.item_of(*b).generics.len > 0) {
                continue;
            }
            val bt = this.block_trait(*b) ?? continue;
            val u = this.union_ids.get(bt.decl);
            var seen: idset = {};
            if (u == null || !this.holds_union(w.ty, *u, &seen)) {
                continue;
            }
            val name = this.decl_name(bt.decl);
            var msg = union_why(&w, pkg, name);
            msg.append(fmt(": a later script can't attach {} to another type", S(name)).as_str());
            put(&this.errors, { span: this.item_of(*b).span, msg: move msg });
            return;
        }
    }
}

// a constant expression worked out now, or none when it can't be (it stays as it is); arithmetic
// that fails at compile time (an overflow, a division by zero) is the global's error
attach fn fold_global(this: checker&, e: expr&, want: u32?) -> compile_error!(tval?) {
    val cv = this.ct_eval_in(this.cx.env, e, want) catch |err| {
        if (arith_error(&err)) {
            return copy err;
        }
        return null;
    };
    val c = this.ct_to_val(cv, want, e.span) catch |err| {
        return null;
    };
    if (!c.pure) {
        return null;
    }
    return c;
}

// literals, names and operators over them, with no calls: a global's initializer that's worked out at
// compile time even when it isn't a { } literal
// is this compile-time error one of arithmetic (what running the expression would panic on too)?
fn arith_error(e: compile_error&) -> bool {
    val m = err_msg(e);
    return contains(m, "overflow") || contains(m, "division by zero") || contains(m, "doesn't fit in");
}

fn foldable(e: expr&) -> bool {
    match (e.kind) {
        .INT(v) => { return true; },
        .FLOAT(v, q) => { return true; },
        .CHAR(v) => { return true; },
        .STR(s&) => { return true; },
        .BOOL(b) => { return true; },
        .NULL => { return true; },
        .PATH(p&) => { return true; },
        .DOT_VARIANT(n) => { return true; },
        .UNARY(op, x) => { return foldable(x); },
        .CAST(x, t&) => { return foldable(x); },
        .FIELD(x, name, g&) => { return foldable(x); },
        .BINARY(op, a, b) => { return foldable(a) && foldable(b); },
        .INDEX(a, b) => { return foldable(a) && foldable(b); },
        .BUILTIN(n, g, a&) => {
            // @cast<T>(x) over a constant
            val ap = ptr_of(a);
            if (n != "cast" || ap == null || ap->len != 1) {
                return false;
            }
            match (*ap->at(0)) {
                .EXPR(x&) => { return foldable(x); },
                default => { return true; }, // a name, parsed as a type
            }
        },
        .TUPLE(xs&) => {
            for (x&) in xs.items() {
                if (!foldable(x)) {
                    return false;
                }
            }
            return true;
        },
        default => { return false; },
    }
}

// a global's initial value: its initializer as a constant of the declared type, or zero
attach fn global_init(this: checker&, l: let_stmt&, span: span) -> compile_error!tval {
    var want: u32? = null;
    if (l.ty) {
        want = try this.decl_type(&l.ty, ptr_of(&l.init)); // T[] takes its length from the initializer
    }
    if (l.init) {
        var v = try this.expr(&l.init, want);
        if (want) {
            v = try this.coerce(v, want, l.init.span);
        }
        // ~x and !x over constants, and operators over u128s past i128's maximum, are pure but not
        // literals: folded too, so the global is a constant (the LLVM backend would set it in a
        // constructor, and code running before that, another constructor or a host calling into a
        // library, would read zero; the C backend can't write a checked - in a global at all)
        if (v.pure && v.lit == null && foldable(&l.init)) {
            val folded = try this.fold_global(&l.init, want);
            if (folded) {
                // only when the constant is the same type (an array global named by a slice global
                // folds to a temporary array, which no slice can point at)
                var f = folded;
                if (want) {
                    f = this.coerce(f, want, l.init.span) catch |err| {
                        return v;
                    };
                }
                if (f.ty == v.ty) {
                    return f;
                }
            }
        }
        if (!v.pure && v.lit == null) {
            // a { x; n } (or a struct whose defaults hold one), or operators over constants
            // (1 << 13, FLAG | 0x10), is worked out now; a call isn't, unless it's to a comptime fn
            var lit = foldable(&l.init);
            match (l.init.kind) {
                .LITERAL(x) => { lit = true; },
                .REPEAT(x, n) => { lit = true; },
                .BLOCK(lab, b) => {
                    if ((lab ?? "") == UPDATE_LABEL) {
                        lit = true; // { ..base, a: x }
                    }
                },
                default => {},
            }
            if (!lit) {
                return fails(l.init.span, "global initializers must be constants");
            }
            val cv = this.ct_eval_in(this.cx.env, &l.init, want) catch |e| {
                if (arith_error(&e)) {
                    return copy e;
                }
                return fails(l.init.span, "global initializers must be constants");
            };
            val c = this.ct_to_val(cv, want, l.init.span) catch |e| {
                return fails(l.init.span, "global initializers must be constants");
            };
            if (!c.pure) {
                return fails(l.init.span, "global initializers must be constants");
            }
            // the declared type, checked: 1 << 9 doesn't fit in a u8
            if (want) {
                return try this.coerce(c, want, l.init.span);
            }
            return c;
        }
        return v;
    }
    val w = want ?? return fails(span, "global needs a type or an initializer");
    return vpure(w, this.ir.zero(w));
}

// the value inside an optional, by pointer (null when absent)
<T: type>
fn ptr_of(o: T?&) -> T* {
    if ((*o).none) {
        return null;
    }
    // the payload sits at the start of an optional (a pointer-like one is the pointer itself)
    return @cast<T*>(@cast<void*>(o));
}

// swap two values in place
<T: type>
fn swap(a: T&, b: T&) -> void {
    val t = @read(a);
    @write(a, @read(b));
    @write(b, move t);
}
