// Bindings for other languages: `voltc bindings NAME --lang c|cpp|rust|zig|python|node|js|ts|json` describes package
// NAME's export fns and the types they use, for programs that call a library built with
// `voltc lib NAME --shared` (or `--static`). Every type crosses in a C form:
// - numbers, bool, pointers (T* and T&), cstr, str (volt_str: a pointer and a length), structs whose
//   fields cross, plain enums (their tag type), error sets (u32 codes), E!T (a struct of the error
//   code and the value) and extern "C" fns, as Volt lays them out;
// - slices T[..] ({ T *ptr; size_t len }) and optionals T? ({ T value; bool has }; a pointer is
//   simply null), also as Volt lays them out;
// - an export struct, which other languages hold by a pointer (a handle) and never look inside:
//   returned by value, the caller owns it and frees it with X_free; as X& or X*, it's lent;
// - owned text (a type with @export_text, like std::string), returned as volt_text: the bytes, and
//   what frees them (volt_text_free);
// - a closure parameter fn(A) -> R: a C function taking the caller's data first, and that data.
// The last three differ from how Volt passes them, so voltc lib adds shims (see shims below).
// Anything else is an error naming the fn and the type.
use std::mem;

// what a type is on the C side
enum shape {
    VOID,
    BOOL,
    INT: int_ty,
    FLOAT: u16,
    CSTR,
    STR,
    PTR: u32,          // to this type (VOID: void*)
    STRUCT: u32,       // struct id
    ENUM: u32,         // enum id: a plain enum
    CODE,              // an error set or anyerror: a u32 code
    RESULT: (u32, u32), // E!T: the error set type, the value type
    ARRAY: (u32, u64),
    FN: u32,           // an extern "C" fn type (its index in bind.fns)
    SLICE: u32,        // T[..]: the element type
    OPT: u32,          // T? (T not a pointer): the value type
    HANDLE: u32,       // an export struct (struct id), by value: an owned handle
    TEXT: u32,         // owned text: the Volt type (a struct with @export_text)
    CLOSURE: u32,      // a fn(A) -> R parameter (its index in bind.closures)
}

// what can sit inside another type's C form (a field, an element, a fn pointer's parameter): not the
// shapes that only work at the edge of an export fn
fn plain(s: shape) -> bool {
    match (s) {
        .TEXT(t) => { return false; },
        .HANDLE(h) => { return false; },
        .CLOSURE(c) => { return false; },
        .OPT(t) => { return false; },
        default => { return true; },
    }
}

// one bindings file being written: the package, the types it needs (in the order they're declared)
struct bind {
    c: checker&;
    pkg: str;
    // struct and enum ids, error set types and result types in the order they're first needed
    structs: std::vec<u32> = {};
    enums: std::vec<u32> = {};
    codes: std::vec<u32> = {};
    results: std::vec<u32> = {};
    fns: std::vec<u32> = {};
    slices: std::vec<u32> = {};   // element types
    opts: std::vec<u32> = {};     // value types
    handles: std::vec<u32> = {};  // export struct ids
    texts: std::vec<u32> = {};    // owned text types
    closures: std::vec<u32> = {}; // fn(A) -> R types
    uses_str: bool = false;
    // structs whose fields are being looked at (a pointer back to one is fine: C declares them first)
    visiting: std::vec<u32> = {};
    // the type that had no C form, when shape_of fails
    bad: u32 = 0;
}

attach fn no_form(this: bind&, t: u32) -> shape? {
    this.bad = t;
    return null;
}

// an inner type's form, which has to be plain (see plain)
attach fn inner(this: bind&, t: u32) -> shape? {
    val s = this.shape_of(t) ?? return null;
    if (!plain(s)) {
        return this.no_form(t);
    }
    return s;
}

fn add_u32(v: std::vec<u32>&, x: u32) -> void {
    if (!has_u32(v, x)) {
        put(v, x);
    }
}

// is struct s an export struct (other languages hold it by a handle)?
attach fn is_handle(this: bind&, s: u32) -> bool {
    match (this.c.item_of(this.c.si(s).decl).kind) {
        .STRUCT(sd&) => { return sd.is_export; },
        default => { return false; },
    }
}

// the method that gives struct s's text, when it has @export_text("method")
attach fn text_method(this: bind&, s: u32) -> str? {
    for (a&) in this.c.item_of(this.c.si(s).decl).attrs.items() {
        match (a.kind) {
            .BUILTIN(n, g, x) => {
                if (n == "export_text") {
                    return attr_str(a);
                }
            },
            default => {},
        }
    }
    return null;
}

// the C form of type t, collecting the declarations it needs; none (with the type in bad) when it has none
attach fn shape_of(this: bind&, t: u32) -> shape? {
    match (*this.c.t.get(t)) {
        .VOID => { return shape::VOID; },
        .BOOL => { return shape::BOOL; },
        .INT(k) => {
            if (k == int_ty::I128 || k == int_ty::U128) {
                return this.no_form(t);
            }
            return shape::INT(k);
        },
        .FLOAT(bits) => {
            if (bits != 32 && bits != 64) {
                return this.no_form(t);
            }
            return shape::FLOAT(bits);
        },
        .CSTR => { return shape::CSTR; },
        .STR => {
            this.uses_str = true;
            return shape::STR;
        },
        .VOIDPTR => { return shape::PTR(VOID); },
        .PTR(x) => { return this.pointer(x); },
        .REF(x) => { return this.pointer(x); },
        .OPT(x) => {
            // a null pointer is "none" for the types that are pointers in C
            match (*this.c.t.get(x)) {
                .REF(y) => { return this.pointer(y); },
                .PTR(y) => { return this.pointer(y); },
                .CSTR => { return shape::CSTR; },
                .FN_PTR(ps, r, va) => { return this.shape_of(x); },
                default => {},
            }
            if (this.c.t.is_niche(x)) {
                return this.no_form(t);
            }
            this.inner(x) ?? return null;
            add_u32(&this.opts, x);
            return shape::OPT(x);
        },
        .ARRAY(elem, n) => {
            this.inner(elem) ?? return null;
            return shape::ARRAY(elem, n);
        },
        .SLICE(elem) => {
            this.inner(elem) ?? return null;
            add_u32(&this.slices, elem);
            return shape::SLICE(elem);
        },
        .STRUCT(s) => {
            if (this.is_handle(s)) {
                add_u32(&this.handles, s);
                return shape::HANDLE(s);
            }
            if (this.text_method(s) != null) {
                add_u32(&this.texts, t);
                return shape::TEXT(t);
            }
            if (has_u32(&this.structs, s) || has_u32(&this.visiting, s)) {
                return shape::STRUCT(s);
            }
            // its fields' structs are declared first (C needs them complete)
            put(&this.visiting, s);
            for (f&) in this.c.si(s).fields.items() {
                this.inner(f.ty) ?? return null;
            }
            this.visiting.pop();
            put(&this.structs, s);
            return shape::STRUCT(s);
        },
        .ENUM(e) => {
            val info = this.c.ei(e);
            if (info.is_error) {
                add_u32(&this.codes, t);
                return shape::CODE;
            }
            if (info.has_payload) {
                return this.no_form(t);
            }
            add_u32(&this.enums, e);
            return shape::ENUM(e);
        },
        .ANYERR => { return shape::CODE; },
        .ERR_UNION(e, x) => {
            this.shape_of(e) ?? return null;
            val v = this.shape_of(x) ?? return null;
            match (v) {
                .CLOSURE(c) => { return this.no_form(x); },
                .OPT(o) => { return this.no_form(x); },
                default => {},
            }
            add_u32(&this.results, t);
            return shape::RESULT(e, x);
        },
        .FN_PTR(ps, r, va) => {
            if (va) {
                return this.no_form(t);
            }
            for (p&) in ps.items() {
                this.inner(*p) ?? return null;
            }
            this.inner(r) ?? return null;
            for (i) in 0..this.fns.len {
                if (*this.fns.at(i) == t) {
                    return shape::FN(@cast<u32>(i));
                }
            }
            put(&this.fns, t);
            return shape::FN(@cast<u32>(this.fns.len - 1));
        },
        .FN_VAL(ps, r) => {
            for (p&) in ps.items() {
                this.inner(*p) ?? return null;
            }
            this.inner(r) ?? return null;
            for (i) in 0..this.closures.len {
                if (*this.closures.at(i) == t) {
                    return shape::CLOSURE(@cast<u32>(i));
                }
            }
            put(&this.closures, t);
            return shape::CLOSURE(@cast<u32>(this.closures.len - 1));
        },
        default => { return this.no_form(t); },
    }
}

attach fn pointer(this: bind&, x: u32) -> shape? {
    if (x != VOID) {
        // a pointer to an export struct is a lent handle
        val s = this.shape_of(x) ?? return null;
        match (s) {
            .TEXT(y) => { return this.no_form(x); },
            .CLOSURE(y) => { return this.no_form(x); },
            .OPT(y) => { return this.no_form(x); },
            default => {},
        }
    }
    return shape::PTR(x);
}

fn has_u32(v: std::vec<u32>&, x: u32) -> bool {
    for (y&) in v.items() {
        if (*y == x) {
            return true;
        }
    }
    return false;
}

// does a type lend export struct s (X& or X*)?
attach fn lends(this: bind&, t: u32, s: u32) -> bool {
    val h = this.lent_handle(t) ?? return false;
    return h == s;
}

// the export struct a type points at (X& or X*), if any
attach fn lent_handle(this: bind&, t: u32) -> u32? {
    match (*this.c.t.get(t)) {
        .REF(x) => { return this.struct_handle(x); },
        .PTR(x) => { return this.struct_handle(x); },
        default => { return null; },
    }
}

attach fn struct_handle(this: bind&, t: u32) -> u32? {
    match (*this.c.t.get(t)) {
        .STRUCT(s) => {
            if (this.is_handle(s)) {
                return s;
            }
        },
        default => {},
    }
    return null;
}

// ---------- the exports ----------

// one function other languages call: a package's export fn, or the X_free that voltc lib adds for
// an export struct
struct entry {
    name: std::string; // the C symbol
    f: u32;         // the export fn (when free_of is none)
    free_of: u32?;  // the export struct an added X_free frees
}

// the export fns of the package, by name
attach fn exports(this: bind&) -> std::vec<u32> {
    var out: std::vec<u32> = {};
    for (i) in 0..this.c.fns.len {
        val f = this.c.fi(@cast<u32>(i));
        match (this.c.dl(f.decl).item.kind) {
            .FN(fd&) => {
                val p = this.c.pkg_of(f.decl);
                if (fd.is_export && p != null && (p ?? "") == this.pkg) {
                    var at = out.len;
                    while (at > 0 && str_less(f.name, this.c.fi(*out.at(at - 1)).name)) {
                        at -= 1;
                    }
                    insert_at(&out, at, @cast<u32>(i));
                }
            },
            default => {},
        }
    }
    return move out;
}

// X_free's name for export struct s
attach fn free_name(this: bind&, s: u32) -> std::string {
    var n = this.local(this.c.si(s).name);
    n.append("_free");
    return move n;
}

// every function in the bindings: the export fns, then an X_free per export struct without one
attach fn entries(this: bind&) -> std::vec<entry> {
    var out: std::vec<entry> = {};
    for (i&) in this.exports().items() {
        put(&out, { name: S(this.c.fi(*i).c_name), f: *i, free_of: null });
    }
    for (s&) in this.handles.items() {
        put(&out, { name: this.free_name(*s), f: 0, free_of: *s });
    }
    return move out;
}

// "WHAT is T, which has no C form" (naming the part of T that doesn't cross, when that's inside it)
attach fn no_c_form(this: bind&, at: span, what: std::string, t: u32) -> compile_error {
    var msg = fmt2("{} is {}, which has no C form", move what, this.c.ty_name(t));
    if (this.bad != t) {
        msg.append(fmt(" (because of the {} in it)", this.c.ty_name(this.bad)).as_str());
    }
    return with_help(fail(at, move msg), S("bindings take numbers, bool, pointers and references, cstr, str, slices, optionals, structs of those, plain enums, error sets, E!T, extern \"C\" fns, closures as parameters, and export structs and owned text (@export_text) as results"));
}

// is a shape an owned result (text, or an export struct by value), directly or as E!T's value?
attach fn owned_result(this: bind&, s: shape) -> bool {
    match (s) {
        .TEXT(t) => { return true; },
        .HANDLE(h) => { return true; },
        .RESULT(e, x) => {
            val v = this.shape_of(x) ?? return false;
            match (v) {
                .TEXT(t) => { return true; },
                .HANDLE(h) => { return true; },
                default => { return false; },
            }
        },
        default => { return false; },
    }
}

// every export fn's types have to cross, each where it's allowed
attach fn check_all(this: bind&) -> compile_error!void {
    for (i&) in this.exports().items() {
        val f = this.c.fi(*i);
        val at = this.c.dl(f.decl).item.span;
        for (p&) in f.params.items() {
            val s = this.shape_of(p.ty) ?? return this.no_c_form(at, fmt2("export fn {}: its parameter {}", S(f.name), S(p.name)), p.ty);
            if (this.owned_result(s)) {
                return with_help(fail(at, fmt3("export fn {}: its parameter {} is {}, which only comes out of export fns", S(f.name), S(p.name), this.c.ty_name(p.ty))), S("take an export struct as X& (or X*); take text as str"));
            }
        }
        val r = this.shape_of(f.ret) ?? return this.no_c_form(at, fmt("export fn {}: its return type", S(f.name)), f.ret);
        match (r) {
            .CLOSURE(c) => { return fail(at, fmt2("export fn {}: it returns {}, and closures only go into export fns", S(f.name), this.c.ty_name(f.ret))); },
            default => {},
        }
    }
    // the names voltc lib adds: X_free for each export struct, and the shims' namespace
    for (i&) in this.exports().items() {
        val f = this.c.fi(*i);
        for (h&) in this.handles.items() {
            if (this.free_name(*h).as_str() == f.c_name) {
                return with_help(fail(this.c.dl(f.decl).item.span, fmt3("export fn {}: voltc lib makes {} itself, to free export struct {}", S(f.c_name), S(f.c_name), S(this.c.si(*h).name))), S("rename this fn; the generated one runs the struct's delete and frees its memory"));
            }
        }
    }
    val pkg_ns = this.c.ns(0).children.get(this.pkg);
    if (pkg_ns != null && this.c.ns(*pkg_ns).children.get("__export") != null) {
        return fail(NO_SPAN, fmt("package {} declares namespace __export, which voltc lib needs for its shims", S(this.pkg)));
    }
    return;
}

// does export fn f need a shim (its C form differs from how Volt passes it)?
attach fn needs_shim(this: bind&, f: u32) -> bool {
    val info = this.c.fi(f);
    for (p&) in info.params.items() {
        match (this.shape_of(p.ty) ?? shape::VOID) {
            .CLOSURE(c) => { return true; },
            default => {},
        }
    }
    return this.owned_result(this.shape_of(info.ret) ?? shape::VOID);
}

// ---------- shims ----------

// What voltc lib compiles in front of a package's export fns whose C form differs from Volt's (owned
// text, export structs by value, closures): Volt source for export fns of the same names in their C
// forms, in namespace PKG::__export, which call the package's own fns (no longer exported); and an
// X_free per export struct. It uses only the language and the runtime's allocator, never std.
struct shim_plan {
    text: std::string = {};
    unexport: std::vec<std::string> = {}; // the package's export fns a shim stands in for (their full names)
}

// a type as Volt source (full names resolve from anywhere)
attach fn src(this: bind&, t: u32) -> std::string {
    return this.c.ty_name(t);
}

// E's spelling before ! in E!T (nothing for anyerror)
attach fn err_src(this: bind&, e: u32) -> std::string {
    if (e == ANYERR) {
        return {};
    }
    return this.src(e);
}

// the expression that turns v (a value of owned type t) into its C form: text_K(v) or own_K(v)
attach fn wrap_owned(this: bind&, t: u32, v: std::string) -> std::string {
    match (this.shape_of(t) ?? shape::VOID) {
        .TEXT(x) => {
            for (k) in 0..this.texts.len {
                if (*this.texts.at(k) == t) {
                    return fmt2("text_{}({})", unum(@cast<u64>(k)), move v);
                }
            }
        },
        .HANDLE(s) => {
            for (k) in 0..this.handles.len {
                if (*this.handles.at(k) == s) {
                    return fmt2("own_{}({})", unum(@cast<u64>(k)), move v);
                }
            }
        },
        default => {},
    }
    return v;
}

// owned type t's C form, as Volt source in the shim: text, or X*
attach fn owned_src(this: bind&, t: u32) -> std::string {
    match (this.shape_of(t) ?? shape::VOID) {
        .TEXT(x) => { return S("text"); },
        .HANDLE(s) => { return fmt("({}*)", this.src(t)); },
        default => { return this.src(t); },
    }
}

// an export fn's full Volt name (mathlib::geo::area), which the shims call it by
attach fn full_name(this: bind&, f: u32) -> std::string {
    val info = this.c.fi(f);
    var n = this.c.ns_path(this.c.dl(info.decl).ns, "::");
    if (n.len() > 0) {
        n.append("::");
    }
    n.append(info.name);
    return move n;
}

attach fn shim_fn(this: bind&, f: u32, out: std::string&) -> void {
    val info = this.c.fi(f);
    var params: std::string = {};
    var args: std::string = {};
    for (p&) in info.params.items() {
        if (params.len() > 0) {
            params.append(", ");
            args.append(", ");
        }
        match (this.shape_of(p.ty) ?? shape::VOID) {
            .CLOSURE(c) => {
                // the caller's C function, which takes the caller's data first, and that data
                match (*this.c.t.get(p.ty)) {
                    .FN_VAL(ps&, r) => {
                        var cps = S("void*");
                        var lps: std::string = {};
                        var largs = S(p.name);
                        largs.append("_user");
                        for (k) in 0..ps.len {
                            cps.append(", ");
                            cps.append(this.src(*ps.at(k)).as_str());
                            if (k > 0) {
                                lps.append(", ");
                            }
                            lps.append(fmt2("a{}: {}", unum(@cast<u64>(k)), this.src(*ps.at(k))).as_str());
                            largs.append(fmt(", a{}", unum(@cast<u64>(k))).as_str());
                        }
                        params.append(fmt4("{}: extern \"C\" fn({}) -> {}, {}_user: void*", S(p.name), move cps, this.src(r), S(p.name)).as_str());
                        var call = fmt2("{}({})", S(p.name), move largs);
                        if (r != VOID) {
                            call = fmt("return {}", move call);
                        }
                        args.append(fmt4("|{}, {}_user| ({}) -> {} {{ ", S(p.name), S(p.name), move lps, this.src(r)).as_str());
                        args.append(call.as_str());
                        args.append("; }");
                    },
                    default => {},
                }
            },
            default => {
                params.append(fmt2("{}: {}", S(p.name), this.src(p.ty)).as_str());
                args.append(p.name);
            },
        }
    }
    val call = fmt2("{}({})", this.full_name(f), move args);
    var ret = this.src(info.ret);
    var body: std::string = {};
    match (this.shape_of(info.ret) ?? shape::VOID) {
        .TEXT(t) => {
            ret = this.owned_src(info.ret);
            body = fmt("return {};", this.wrap_owned(info.ret, move call));
        },
        .HANDLE(s) => {
            ret = this.owned_src(info.ret);
            body = fmt("return {};", this.wrap_owned(info.ret, move call));
        },
        .RESULT(e, x) => {
            if (this.owned_result(shape::RESULT(e, x))) {
                ret = fmt2("{}!{}", this.err_src(e), this.owned_src(x));
                body = fmt("return {};", this.wrap_owned(x, fmt("try {}", move call)));
            } else {
                body = fmt("return {};", move call);
            }
        },
        .VOID => { body = fmt("{};", move call); },
        default => { body = fmt("return {};", move call); },
    }
    out.append(fmt4("\n    export fn {}({}) -> {} {{\n        {}\n    }}\n", S(info.c_name), move params, move ret, move body).as_str());
}

// the shims for package pkg (an empty text when it needs none)
attach fn shims(this: checker&, pkg: str) -> compile_error!shim_plan {
    var b: bind = { c: this, pkg: pkg };
    try b.check_all();
    var plan: shim_plan = {};
    var fns: std::string = {};
    for (i&) in b.exports().items() {
        if (b.needs_shim(*i)) {
            b.shim_fn(*i, &fns);
            put(&plan.unexport, b.full_name(*i));
        }
    }
    val ents = b.entries();
    if (fns.len() == 0 && b.handles.len == 0) {
        return move plan;
    }
    var out = S("// generated by voltc lib: the package's export fns in the forms other languages call\n// (see voltc bindings)\nnamespace __export {\n    @attributes([@intrinsic(\"volt_rt_malloc\")])\n    internal fn rt_malloc(size: usize) -> void*;\n    @attributes([@intrinsic(\"volt_rt_free\")])\n    internal fn rt_free(ptr: void*) -> void;\n");
    if (b.texts.len > 0) {
        out.append("\n    // owned text: the bytes, and what frees them (drop(owner))\n    struct text {\n        ptr: u8*;\n        len: usize;\n        owner: void*;\n        drop: extern \"C\" fn(void*) -> void;\n    }\n");
    }
    for (k) in 0..b.texts.len {
        val t = *b.texts.at(k);
        val ts = b.src(t);
        var method = S("as_str");
        match (*this.t.get(t)) {
            .STRUCT(s) => { method = S(b.text_method(s) ?? "as_str"); },
            default => {},
        }
        val kk = unum(@cast<u64>(k));
        out.append(fmt2("\n    extern \"C\" fn drop_text_{}(p: void*) -> void {{\n        val v = @read(@cast<{}*>(p));\n        rt_free(p);\n    }}\n", copy kk, copy ts).as_str());
        out.append(fmt4("\n    fn text_{}(v: {}) -> text {{\n        val p = @cast<{}*>(rt_malloc(@sizeof({})) ?? @panic(\"out of memory\"));\n", copy kk, copy ts, copy ts, copy ts).as_str());
        out.append(fmt2("        @write(p, move v);\n        val s = p->{}();\n        return {{ ptr: s.ptr, len: s.len, owner: p, drop: drop_text_{} }};\n    }}\n", move method, copy kk).as_str());
    }
    for (k) in 0..b.handles.len {
        val s = *b.handles.at(k);
        val xs = S(this.si(s).name);
        val kk = unum(@cast<u64>(k));
        out.append(fmt4("\n    fn own_{}(v: {}) -> {}* {{\n        val p = @cast<{}*>(rt_malloc(@sizeof(", copy kk, copy xs, copy xs, copy xs).as_str());
        out.append(fmt("{})) ?? @panic(\"out of memory\"));\n        @write(p, move v);\n        return p;\n    }\n", copy xs).as_str());
    }
    for (e&) in ents.items() {
        val s = e.free_of ?? continue;
        out.append(fmt2("\n    // frees what an export fn gave out (null does nothing)\n    export fn {}(it: {}*) -> void {{\n        if (it == null) {{\n            return;\n        }}\n        val v = @read(it);\n        rt_free(@cast<void*>(it));\n    }}\n", copy e.name, S(this.si(s).name)).as_str());
    }
    out.append(fns.as_str());
    out.append("}\n");
    plan.text = move out;
    return move plan;
}

// a declared name as bindings spell it: without the package's own namespace, and as an identifier
// (mathlib::geo::point<i32> becomes geo_point_i32)
attach fn local(this: bind&, name: str) -> std::string {
    if (name.len > this.pkg.len + 2 && name[0..this.pkg.len] == this.pkg && name[this.pkg.len..this.pkg.len + 2] == "::") {
        return ident_of(name[this.pkg.len + 2..name.len]);
    }
    return ident_of(name);
}

// a Volt name as an identifier: vec<i32> becomes vec_i32
fn ident_of(s: str) -> std::string {
    var out: std::string = {};
    for (c) in s {
        if (is_alpha(c) || is_digit(c) || c == '_') {
            out.push(c);
        } else if (out.len() > 0 && *out.bytes.at(out.len() - 1) != '_') {
            out.push('_');
        }
    }
    while (out.len() > 0 && *out.bytes.at(out.len() - 1) == '_') {
        out.bytes.pop();
    }
    return move out;
}

fn upper(s: str) -> std::string {
    var out: std::string = {};
    for (c) in s {
        if (c >= 'a' && c <= 'z') {
            out.push(c - 32);
        } else {
            out.push(c);
        }
    }
    return move out;
}

// the short name of a type in bindings (a struct's or enum's own name, i32, f64, text...)
attach fn short(this: bind&, t: u32) -> std::string {
    match (*this.c.t.get(t)) {
        .STRUCT(s) => {
            if (this.text_method(s) != null) {
                return S("text");
            }
            return this.local(this.c.si(s).name);
        },
        .ENUM(e) => { return this.local(this.c.ei(e).name); },
        .ANYERR => { return S("error"); },
        default => { return ident_of(this.c.ty_name(t).as_str()); },
    }
}

// E!T's struct name: math_error_or_f64
attach fn result_name(this: bind&, t: u32) -> std::string {
    match (*this.c.t.get(t)) {
        .ERR_UNION(e, x) => {
            var n = this.short(e);
            n.append("_or_");
            n.append(this.short(x).as_str());
            return move n;
        },
        default => { return this.short(t); },
    }
}

// the name of a generated type: pkg_KIND_T in C, KIND_T in C++ (inside namespace pkg)
attach fn made_name(this: bind&, kind: str, t: u32, cpp: bool) -> std::string {
    var n = S(kind);
    n.push('_');
    n.append(this.short(t).as_str());
    return this.c_named(n.as_str(), cpp);
}

attach fn cb_name(this: bind&, i: u32, cpp: bool) -> std::string {
    var n = S("cb");
    n.append_uint(@cast<u64>(i));
    return this.c_named(n.as_str(), cpp);
}

// a declared type's name: pkg_name in C, name in C++ (inside namespace pkg)
attach fn c_named(this: bind&, name: str, cpp: bool) -> std::string {
    if (cpp) {
        return this.local(name);
    }
    var n = S(this.pkg);
    n.push('_');
    n.append(this.local(name).as_str());
    return move n;
}

// an export struct's handle type: a pointer to pkg_X in C, to raw::X in C++
attach fn handle_c(this: bind&, s: u32, cpp: bool) -> std::string {
    if (cpp) {
        return fmt("raw::{} *", this.local(this.c.si(s).name));
    }
    return fmt("{} *", this.c_named(this.c.si(s).name, false));
}

attach fn c_prim(this: bind&, t: u32, cpp: bool) -> std::string {
    val sh = this.shape_of(t) ?? return S("void");
    match (sh) {
        .VOID => { return S("void"); },
        .BOOL => { return S("bool"); },
        .INT(k) => { return S(int_c(k)); },
        .FLOAT(b) => {
            if (b == 32) {
                return S("float");
            }
            return S("double");
        },
        .CSTR => { return S("const char *"); },
        .STR => {
            if (cpp) {
                return S("str");
            }
            return S("volt_str");
        },
        .PTR(x) => {
            if (x != VOID) {
                match (this.shape_of(x) ?? shape::VOID) {
                    .HANDLE(s) => { return this.handle_c(s, cpp); },
                    default => {},
                }
            }
            var s = this.c_prim(x, cpp);
            if (!ends_with(s.as_str(), "*")) {
                s.push(' ');
            }
            s.push('*');
            return move s;
        },
        .STRUCT(s) => { return this.c_named(this.c.si(s).name, cpp); },
        .ENUM(e) => { return this.c_named(this.c.ei(e).name, cpp); },
        .CODE => { return S("uint32_t"); },
        .RESULT(e, x) => { return this.c_named(this.result_name(t).as_str(), cpp); },
        .ARRAY(elem, n) => { return this.c_prim(elem, cpp); },
        .FN(i) => {
            var n = S(this.pkg);
            n.append("_fn");
            n.append_uint(@cast<u64>(i));
            if (cpp) {
                n = S("fn");
                n.append_uint(@cast<u64>(i));
            }
            return move n;
        },
        .SLICE(x) => { return this.made_name("slice", x, cpp); },
        .OPT(x) => { return this.made_name("opt", x, cpp); },
        .HANDLE(s) => { return this.handle_c(s, cpp); },
        .TEXT(x) => {
            if (cpp) {
                return S("text");
            }
            return S("volt_text");
        },
        .CLOSURE(i) => { return this.cb_name(i, cpp); },
    }
}

// a C type ready for a name after it: "int " but "char *"
fn spaced(t: std::string) -> std::string {
    var s = move t;
    if (!ends_with(s.as_str(), "*")) {
        s.push(' ');
    }
    return move s;
}

// "T name" (with [N] after the name for arrays)
attach fn c_decl(this: bind&, t: u32, name: str, cpp: bool) -> std::string {
    var s = this.c_prim(t, cpp);
    if (!ends_with(s.as_str(), "*")) {
        s.push(' ');
    }
    if (cpp) {
        s.append(cpp_ident(name).as_str());
    } else {
        s.append(name);
    }
    var cur = t;
    loop {
        match (*this.c.t.get(cur)) {
            .ARRAY(elem, n) => {
                s.push('[');
                s.append_uint(n);
                s.push(']');
                cur = elem;
            },
            default => { break; },
        }
    }
    return move s;
}

// an export's C parameter list (a closure is the function and the caller's data)
attach fn c_params(this: bind&, e: entry&, cpp: bool) -> std::string {
    var args: std::string = {};
    val s = e.free_of;
    if (s) {
        return this.c_decl_handle(s, cpp);
    }
    val f = this.c.fi(e.f);
    for (p&) in f.params.items() {
        if (args.len() > 0) {
            args.append(", ");
        }
        args.append(this.c_decl(p.ty, p.name, cpp).as_str());
        match (this.shape_of(p.ty) ?? shape::VOID) {
            .CLOSURE(i) => { args.append(fmt(", void *{}_user", S(p.name)).as_str()); },
            default => {},
        }
    }
    if (f.params.len == 0) {
        args.append("void");
    }
    return move args;
}

attach fn c_decl_handle(this: bind&, s: u32, cpp: bool) -> std::string {
    var d = this.handle_c(s, cpp);
    d.append("it");
    return move d;
}

attach fn c_ret(this: bind&, e: entry&, cpp: bool) -> std::string {
    if (e.free_of != null) {
        return S("void");
    }
    return this.c_prim(this.c.fi(e.f).ret, cpp);
}

// the declarations both C and C++ share, in an order C accepts: what's only pointed at first
attach fn c_types(this: bind&, cpp: bool, out: std::string&) -> void {
    for (s&) in this.structs.items() {
        val n = this.c_named(this.c.si(*s).name, cpp);
        if (cpp) {
            out.append(fmt("struct {};\n", copy n).as_str());
        } else {
            out.append(fmt2("typedef struct {} {};\n", copy n, copy n).as_str());
        }
    }
    if (!cpp) {
        for (s&) in this.handles.items() {
            val n = this.c_named(this.c.si(*s).name, false);
            out.append(fmt3("// export struct {}: held by a handle, freed with {}\ntypedef struct {} ", S(this.c.si(*s).name), this.free_name(*s), copy n).as_str());
            out.append(fmt("{};\n", copy n).as_str());
        }
    }
    for (e&) in this.enums.items() {
        val info = this.c.ei(*e);
        val n = this.c_named(info.name, cpp);
        if (cpp) {
            out.append(fmt2("\nenum class {} : {} {{\n", copy n, S(int_c(info.tag))).as_str());
            for (i) in 0..info.names.len {
                out.append(fmt2("    {} = {},\n", S(*info.names.at(i)), num(*info.values.at(i))).as_str());
            }
            out.append("};\n");
        } else {
            out.append(fmt2("\ntypedef {} {};\nenum {{\n", S(int_c(info.tag)), copy n).as_str());
            for (i) in 0..info.names.len {
                out.append(fmt3("    {}_{} = {},\n", upper(n.as_str()), S(*info.names.at(i)), num(*info.values.at(i))).as_str());
            }
            out.append("};\n");
        }
    }
    for (et&) in this.codes.items() {
        match (*this.c.t.get(*et)) {
            .ENUM(e) => {
                val info = this.c.ei(e);
                val n = this.c_named(info.name, cpp);
                out.append(fmt("\n// the codes of error set {} (0 means no error)\n", S(info.name)).as_str());
                if (cpp) {
                    out.append(fmt("struct {} {{\n", copy n).as_str());
                }
                for (i) in 0..info.names.len {
                    if (cpp) {
                        out.append(fmt2("    static constexpr uint32_t {} = {}u;\n", S(*info.names.at(i)), num(*info.values.at(i))).as_str());
                    } else {
                        out.append(fmt3("#define {}_{} {}u\n", upper(n.as_str()), S(*info.names.at(i)), num(*info.values.at(i))).as_str());
                    }
                }
                if (cpp) {
                    out.append("};\n");
                }
            },
            default => {},
        }
    }
    if (cpp) {
        this.cpp_errors(out);
    }
    for (x&) in this.slices.items() {
        val n = this.made_name("slice", *x, cpp);
        val elem = this.c_prim(*x, cpp);
        if (cpp) {
            out.append(fmt2("\n// a Volt slice: elements and how many (made from a vector or an array)\nstruct {} {{\n    {} *ptr;\n    size_t len;\n", copy n, copy elem).as_str());
            out.append(fmt3("    {}({} *p, size_t n) : ptr(p), len(n) {{}}\n    template <size_t N> {}(", copy n, copy elem, copy n).as_str());
            out.append(fmt("{} (&a)[N]) : ptr(a), len(N) {{}}\n", copy elem).as_str());
            if (elem.as_str() != "bool") {
                out.append(fmt2("    {}(std::vector<{}> &v) : ptr(v.data()), len(v.size()) {{}}\n", copy n, copy elem).as_str());
            }
            out.append("};\n");
        } else {
            out.append(fmt2("\n// a Volt slice: elements and how many\ntypedef struct {{\n    {} *ptr;\n    size_t len;\n}} {};\n", copy elem, copy n).as_str());
        }
    }
    for (i) in 0..this.fns.len {
        match (*this.c.t.get(*this.fns.at(i))) {
            .FN_PTR(ps, r, va) => {
                var args: std::string = {};
                for (k) in 0..ps.len {
                    if (k > 0) {
                        args.append(", ");
                    }
                    args.append(this.c_prim(*ps.at(k), cpp).as_str());
                }
                if (ps.len == 0) {
                    args.append("void");
                }
                out.append(fmt3("typedef {} (*{})({});\n", this.c_prim(r, cpp), this.c_prim(*this.fns.at(i), cpp), move args).as_str());
            },
            default => {},
        }
    }
    for (i) in 0..this.closures.len {
        match (*this.c.t.get(*this.closures.at(i))) {
            .FN_VAL(ps, r) => {
                var args = S("void *user");
                for (k) in 0..ps.len {
                    args.append(", ");
                    args.append(this.c_prim(*ps.at(k), cpp).as_str());
                }
                out.append(fmt3("\n// a callback: called with the data passed along with it, then {}'s arguments\ntypedef {} (*{})(", this.c.ty_name(*this.closures.at(i)), this.c_prim(r, cpp), this.cb_name(@cast<u32>(i), cpp)).as_str());
                out.append(fmt("{});\n", move args).as_str());
            },
            default => {},
        }
    }
    for (s&) in this.structs.items() {
        val info = this.c.si(*s);
        out.append(fmt("\nstruct {} {{\n", this.c_named(info.name, cpp)).as_str());
        for (f&) in info.fields.items() {
            out.append(fmt("    {};\n", this.c_decl(f.ty, f.name, cpp)).as_str());
        }
        out.append("};\n");
    }
    for (x&) in this.opts.items() {
        val n = this.made_name("opt", *x, cpp);
        if (cpp) {
            out.append(fmt2("\n// a Volt optional: has says whether value is there\nstruct {} {{\n    {} value;\n    bool has;\n}};\n", copy n, this.c_prim(*x, cpp)).as_str());
        } else {
            out.append(fmt2("\n// a Volt optional: has says whether value is there\ntypedef struct {{\n    {} value;\n    bool has;\n}} {};\n", this.c_prim(*x, cpp), copy n).as_str());
        }
    }
    for (rt&) in this.results.items() {
        match (*this.c.t.get(*rt)) {
            .ERR_UNION(e, x) => {
                out.append(fmt("\n// {}: error is 0, or the error's code\n", this.c.ty_name(*rt)).as_str());
                out.append(fmt("struct {} {{\n    uint32_t error;\n", this.c_named(this.result_name(*rt).as_str(), cpp)).as_str());
                if (x != VOID) {
                    out.append(fmt("    {};\n", this.c_decl(x, "value", cpp)).as_str());
                }
                out.append("};\n");
                if (!cpp) {
                    val n = this.c_named(this.result_name(*rt).as_str(), false);
                    out.append(fmt2("typedef struct {} {};\n", copy n, copy n).as_str());
                }
            },
            default => {},
        }
    }
}

attach fn c_text(this: bind&) -> std::string {
    val guard = upper(this.pkg);
    val ents = this.entries();
    var out: std::string = {};
    out.append(fmt("// {}: generated by voltc bindings; the C interface of the Volt package\n", S(this.pkg)).as_str());
    out.append(fmt("// {} (build it with voltc lib NAME --shared or --static)\n", S(this.pkg)).as_str());
    out.append(fmt2("#ifndef {}_H\n#define {}_H\n#include <stdbool.h>\n#include <stddef.h>\n#include <stdint.h>\n\n#ifdef __cplusplus\nextern \"C\" {{\n#endif\n\n", copy guard, copy guard).as_str());
    if (this.uses_str) {
        out.append("#ifndef VOLT_STR_DEFINED\n#define VOLT_STR_DEFINED\n// a Volt str: bytes and a length (no terminator)\ntypedef struct {\n    const uint8_t *ptr;\n    size_t len;\n} volt_str;\n#endif\n\n");
    }
    if (this.texts.len > 0) {
        out.append("#ifndef VOLT_TEXT_DEFINED\n#define VOLT_TEXT_DEFINED\n// owned text a Volt function gave out: bytes and a length (no terminator); free it with\n// volt_text_free once you're done with the bytes\ntypedef struct {\n    const uint8_t *ptr;\n    size_t len;\n    void *owner;\n    void (*drop)(void *owner);\n} volt_text;\n\nstatic inline void volt_text_free(volt_text t) {\n    if (t.drop) {\n        t.drop(t.owner);\n    }\n}\n#endif\n\n");
    }
    this.c_types(false, &out);
    out.append("\n");
    for (e&) in ents.items() {
        out.append(fmt3("{}{}({});\n", spaced(this.c_ret(e, false)), copy e.name, this.c_params(e, false)).as_str());
    }
    out.append(fmt("\n#ifdef __cplusplus\n}\n#endif\n#endif // {}_H\n", copy guard).as_str());
    return move out;
}

// ---------- C++ ----------

// the C++ keywords a Volt name might be
fn cpp_keyword(s: str) -> bool {
    val words: str[] = { "new", "delete", "class", "default", "operator", "template", "this", "virtual", "public", "private", "protected", "friend", "typename", "namespace", "using", "auto", "register", "union", "signed", "unsigned", "char", "int", "long", "short", "float", "double", "bool", "void", "const", "static", "extern", "volatile", "inline", "explicit", "export", "throw", "try", "catch", "switch", "case", "goto", "sizeof", "typedef", "struct", "enum", "return", "if", "else", "while", "do", "for", "break", "continue", "and", "or", "not", "xor" };
    for (w) in words {
        if (w == s) {
            return true;
        }
    }
    return false;
}

fn cpp_ident(s: str) -> std::string {
    var n = S(s);
    if (cpp_keyword(s)) {
        n.push('_');
    }
    return move n;
}

// error_name and the error exception: every code of every error set the package uses
attach fn cpp_errors(this: bind&, out: std::string&) -> void {
    if (this.codes.len == 0) {
        return;
    }
    out.append("\n// the name of an error code\ninline const char *error_name(uint32_t code) {\n    switch (code) {\n");
    var seen: std::vec<i128> = {};
    for (et&) in this.codes.items() {
        match (*this.c.t.get(*et)) {
            .ENUM(e) => {
                val info = this.c.ei(e);
                for (i) in 0..info.names.len {
                    val v = *info.values.at(i);
                    var dup = false;
                    for (s&) in seen.items() {
                        if (*s == v) {
                            dup = true;
                        }
                    }
                    if (!dup) {
                        put(&seen, v);
                        out.append(fmt2("    case {}u: return \"{}\";\n", num(v), S(*info.names.at(i))).as_str());
                    }
                }
            },
            default => {},
        }
    }
    out.append("    }\n    return \"error\";\n}\n\n// what a function throws when the Volt function returns an error\nstruct error : std::runtime_error {\n    uint32_t code;\n    explicit error(uint32_t c) : std::runtime_error(error_name(c)), code(c) {}\n};\n");
}

// what a wrapper's parameter is in C++, and the C argument(s) it passes
attach fn cpp_param(this: bind&, t: u32, name0: str, ty: std::string&, arg: std::string&) -> void {
    val nm = cpp_ident(name0);
    val name = nm.as_str();
    val h = this.lent_handle(t);
    if (h) {
        val cls = this.local(this.c.si(h).name);
        match (*this.c.t.get(t)) {
            .REF(x) => {
                ty.append(fmt2("{} &{}", move cls, S(name)).as_str());
                arg.append(fmt("{}.get()", S(name)).as_str());
            },
            default => {
                ty.append(fmt2("{} *{}", move cls, S(name)).as_str());
                arg.append(fmt2("({} ? {}->get() : nullptr)", S(name), S(name)).as_str());
            },
        }
        return;
    }
    match (this.shape_of(t) ?? shape::VOID) {
        .OPT(x) => {
            val v = this.c_prim(x, true);
            ty.append(fmt2("std::optional<{}> {}", copy v, S(name)).as_str());
            arg.append(fmt4("{}{{{}.value_or({}{{}}), {}.has_value()}}", this.made_name("opt", x, true), S(name), copy v, S(name)).as_str());
        },
        .CLOSURE(i) => {
            match (*this.c.t.get(t)) {
                .FN_VAL(ps&, r) => {
                    var sig = this.c_prim(r, true);
                    sig.push('(');
                    var lps = S("void *u");
                    var largs: std::string = {};
                    for (k) in 0..ps.len {
                        if (k > 0) {
                            sig.append(", ");
                            largs.append(", ");
                        }
                        sig.append(this.c_prim(*ps.at(k), true).as_str());
                        lps.append(fmt2(", {} a{}", this.c_prim(*ps.at(k), true), unum(@cast<u64>(k))).as_str());
                        largs.append(fmt("a{}", unum(@cast<u64>(k))).as_str());
                    }
                    sig.push(')');
                    ty.append(fmt2("std::function<{}> {}", copy sig, S(name)).as_str());
                    arg.append(fmt4("[]({}) -> {} {{ return (*static_cast<std::function<{}> *>(u))({}); }}", move lps, this.c_prim(r, true), copy sig, move largs).as_str());
                    arg.append(fmt(", &{}", S(name)).as_str());
                },
                default => {},
            }
        },
        default => {
            match (*this.c.t.get(t)) {
                .REF(x) => {
                    ty.append(fmt2("{} &{}", this.c_prim(x, true), S(name)).as_str());
                    arg.append(fmt("&{}", S(name)).as_str());
                },
                default => {
                    ty.append(this.c_decl(t, name, true).as_str());
                    arg.append(name);
                },
            }
        },
    }
}

// what a wrapper returns in C++ for a C result of type t
attach fn cpp_ret(this: bind&, t: u32) -> std::string {
    match (this.shape_of(t) ?? shape::VOID) {
        .STR => { return S("std::string"); },
        .TEXT(x) => { return S("std::string"); },
        .HANDLE(s) => { return this.local(this.c.si(s).name); },
        .OPT(x) => { return fmt("std::optional<{}>", this.c_prim(x, true)); },
        .RESULT(e, x) => { return this.cpp_ret(x); },
        default => { return this.c_prim(t, true); },
    }
}

// the C++ value of C result r (of type t)
attach fn cpp_value(this: bind&, t: u32, r: str) -> std::string {
    match (this.shape_of(t) ?? shape::VOID) {
        .STR => { return fmt2("std::string((const char *){}.ptr, {}.len)", S(r), S(r)); },
        .TEXT(x) => { return fmt("take_text({})", S(r)); },
        .HANDLE(s) => { return fmt2("{}({})", this.local(this.c.si(s).name), S(r)); },
        .OPT(x) => { return fmt3("{}.has ? std::optional<{}>({}.value) : std::nullopt", S(r), this.c_prim(x, true), S(r)); },
        default => { return S(r); },
    }
}

// a wrapper's body: call the C function with args, throw its error, return its value
attach fn cpp_body(this: bind&, f: u32, args: std::string) -> std::string {
    val info = this.c.fi(f);
    val call = fmt2("raw::{}({})", S(info.c_name), move args);
    if (info.ret == VOID) {
        return fmt("    {};\n", move call);
    }
    var out = fmt("    auto r = {};\n", move call);
    match (this.shape_of(info.ret) ?? shape::VOID) {
        .RESULT(e, x) => {
            out.append("    if (r.error != 0) {\n        throw error(r.error);\n    }\n");
            if (x != VOID) {
                out.append(fmt("    return {};\n", this.cpp_value(x, "r.value")).as_str());
            }
        },
        default => { out.append(fmt("    return {};\n", this.cpp_value(info.ret, "r")).as_str()); },
    }
    return move out;
}

// export struct s's part of an export fn's name (counter_add: add), when f belongs to its class:
// it takes s as its first parameter, or makes one (returns s, or E!s)
attach fn member_of(this: bind&, f: u32, s: u32) -> str? {
    val info = this.c.fi(f);
    var prefix = this.local(this.c.si(s).name);
    prefix.push('_');
    if (!starts_with(info.c_name, prefix.as_str()) || info.c_name.len == prefix.len()) {
        return null;
    }
    val m = info.c_name[prefix.len()..info.c_name.len];
    if (info.params.len > 0 && this.lends(info.params.at(0).ty, s)) {
        return m;
    }
    if (this.made_by(f, s)) {
        return m;
    }
    return null;
}

// does f make export struct s (return it by value, or as E!T's value)?
attach fn made_by(this: bind&, f: u32, s: u32) -> bool {
    val m = this.makes(f) ?? return false;
    return m == s;
}

// the export struct f returns by value (or as E!T's value)
attach fn makes(this: bind&, f: u32) -> u32? {
    match (this.shape_of(this.c.fi(f).ret) ?? shape::VOID) {
        .HANDLE(s) => { return s; },
        .RESULT(e, x) => {
            match (this.shape_of(x) ?? shape::VOID) {
                .HANDLE(s) => { return s; },
                default => {},
            }
        },
        default => {},
    }
    return null;
}

// the class an export fn is a member of (and its member name)
attach fn class_of(this: bind&, f: u32) -> u32? {
    for (s&) in this.handles.items() {
        if (this.member_of(f, *s) != null) {
            return *s;
        }
    }
    return null;
}

attach fn cpp_text(this: bind&) -> std::string {
    val ents = this.entries();
    var out: std::string = {};
    out.append(fmt("// {}: generated by voltc bindings; the Volt package for C++17\n", S(this.pkg)).as_str());
    out.append("// (build it with voltc lib NAME --shared or --static). Errors are thrown as error.\n");
    out.append("#pragma once\n#include <cstddef>\n#include <cstdint>\n#include <cstring>\n#include <functional>\n#include <optional>\n#include <stdexcept>\n#include <string>\n#include <string_view>\n#include <utility>\n#include <vector>\n\n");
    out.append(fmt("namespace {} {{\n\n", S(this.pkg)).as_str());
    if (this.uses_str) {
        out.append("// a Volt str: bytes and a length (no terminator)\nstruct str {\n    const uint8_t *ptr;\n    size_t len;\n    str(const char *s) : ptr((const uint8_t *)s), len(std::strlen(s)) {}\n    str(std::string_view s) : ptr((const uint8_t *)s.data()), len(s.size()) {}\n    str(const std::string &s) : ptr((const uint8_t *)s.data()), len(s.size()) {}\n    std::string_view view() const { return {(const char *)ptr, len}; }\n};\n\n");
    }
    if (this.texts.len > 0) {
        out.append("// owned text a Volt function gave out (the wrappers copy it into a std::string and free it)\nstruct text {\n    const uint8_t *ptr;\n    size_t len;\n    void *owner;\n    void (*drop)(void *owner);\n};\n\ninline std::string take_text(text t) {\n    std::string s((const char *)t.ptr, t.len);\n    if (t.drop) {\n        t.drop(t.owner);\n    }\n    return s;\n}\n\n");
    }
    this.c_types(true, &out);
    // the C functions, as they are
    out.append("\n// the C functions (the wrappers below are easier to use)\nnamespace raw {\n");
    for (s&) in this.handles.items() {
        out.append(fmt("struct {};\n", this.local(this.c.si(*s).name)).as_str());
    }
    out.append("extern \"C\" {\n");
    for (e&) in ents.items() {
        out.append(fmt3("{}{}({});\n", spaced(this.c_ret(e, true)), copy e.name, this.c_params(e, true)).as_str());
    }
    out.append("}\n}  // namespace raw\n");
    // a class per export struct: it owns its handle
    for (s&) in this.handles.items() {
        val cls = this.local(this.c.si(*s).name);
        out.append(fmt3("\n// export struct {}: owns a handle, and frees it when it goes away\nclass {} {{\n    raw::{} *p_;\n\npublic:\n", S(this.c.si(*s).name), copy cls, copy cls).as_str());
        out.append(fmt2("    explicit {}(raw::{} *p) : p_(p) {{}}\n", copy cls, copy cls).as_str());
        out.append(fmt3("    {}({} &&o) noexcept : p_(o.p_) {{\n        o.p_ = nullptr;\n    }}\n    {} &operator=(", copy cls, copy cls, copy cls).as_str());
        out.append(fmt3("{} &&o) noexcept {{\n        std::swap(p_, o.p_);\n        return *this;\n    }}\n    {}(const {} &) = delete;\n", copy cls, copy cls, copy cls).as_str());
        out.append(fmt3("    {} &operator=(const {} &) = delete;\n    ~{}() {{\n", copy cls, copy cls, copy cls).as_str());
        out.append(fmt("        if (p_) {\n            raw::{}(p_);\n        }\n    }\n    raw::", this.free_name(*s)).as_str());
        out.append(fmt("{} *get() const {\n        return p_;\n    }\n", copy cls).as_str());
        for (e&) in ents.items() {
            if (e.free_of != null) {
                continue;
            }
            val m = this.member_of(e.f, *s) ?? continue;
            val info = this.c.fi(e.f);
            var ps: std::string = {};
            var first: usize = 0;
            if (!this.made_by(e.f, *s) || (info.params.len > 0 && this.lends(info.params.at(0).ty, *s))) {
                first = 1;
            }
            for (k) in first..info.params.len {
                if (ps.len() > 0) {
                    ps.append(", ");
                }
                var a: std::string = {};
                this.cpp_param(info.params.at(k).ty, info.params.at(k).name, &ps, &a);
            }
            if (first == 0 && m == "new") {
                out.append(fmt2("    {}({});\n", copy cls, move ps).as_str());
            } else if (first == 0) {
                out.append(fmt3("    static {} {}({});\n", this.cpp_ret(info.ret), cpp_ident(m), move ps).as_str());
            } else {
                out.append(fmt3("    {} {}({});\n", this.cpp_ret(info.ret), cpp_ident(m), move ps).as_str());
            }
        }
        out.append("};\n");
    }
    // the wrappers
    for (e&) in ents.items() {
        if (e.free_of != null) {
            continue;
        }
        val info = this.c.fi(e.f);
        val cls_id = this.class_of(e.f);
        var ps: std::string = {};
        var args: std::string = {};
        var first: usize = 0;
        if (cls_id) {
            if (info.params.len > 0 && this.lends(info.params.at(0).ty, cls_id)) {
                first = 1;
                args.append("p_");
            }
        }
        for (k) in first..info.params.len {
            if (ps.len() > 0) {
                ps.append(", ");
            }
            if (args.len() > 0) {
                args.append(", ");
            }
            this.cpp_param(info.params.at(k).ty, info.params.at(k).name, &ps, &args);
        }
        if (cls_id) {
            val cls = this.local(this.c.si(cls_id).name);
            val m = this.member_of(e.f, cls_id) ?? "";
            if (first == 0 && m == "new") {
                // the constructor takes the handle the C function makes
                out.append(fmt4("\ninline {}::{}({}) : p_(nullptr) {{\n    auto r = raw::{}(", copy cls, copy cls, move ps, S(info.c_name)).as_str());
                out.append(fmt("{});\n", move args).as_str());
                match (this.shape_of(info.ret) ?? shape::VOID) {
                    .RESULT(er, x) => { out.append("    if (r.error != 0) {\n        throw error(r.error);\n    }\n    p_ = r.value;\n}\n"); },
                    default => { out.append("    p_ = r;\n}\n"); },
                }
            } else {
                out.append(fmt4("\ninline {} {}::{}({}) {{\n", this.cpp_ret(info.ret), copy cls, cpp_ident(m), move ps).as_str());
                out.append(this.cpp_body(e.f, move args).as_str());
                out.append("}\n");
            }
        } else {
            out.append(fmt3("\ninline {} {}({}) {{\n", this.cpp_ret(info.ret), cpp_ident(info.c_name), move ps).as_str());
            out.append(this.cpp_body(e.f, move args).as_str());
            out.append("}\n");
        }
    }
    out.append(fmt("\n}  // namespace {}\n", S(this.pkg)).as_str());
    return move out;
}

// ---------- shared by the generators ----------

// every code of every error set the package uses, once each (codes are the same in every set that
// has the name): (code, name, the error set's local name)
struct code_name {
    code: i128;
    name: str;
    set: std::string;
}

attach fn all_codes(this: bind&) -> std::vec<code_name> {
    var out: std::vec<code_name> = {};
    for (et&) in this.codes.items() {
        match (*this.c.t.get(*et)) {
            .ENUM(e) => {
                val info = this.c.ei(e);
                for (i) in 0..info.names.len {
                    val v = *info.values.at(i);
                    var dup = false;
                    for (s&) in out.items() {
                        if (s.code == v) {
                            dup = true;
                        }
                    }
                    if (!dup) {
                        put(&out, { code: v, name: *info.names.at(i), set: this.local(info.name) });
                    }
                }
            },
            default => {},
        }
    }
    return move out;
}

// ---------- Rust ----------

fn rust_keyword(s: str) -> bool {
    val words: str[] = { "as", "break", "const", "continue", "crate", "else", "enum", "extern", "false", "fn", "for", "if", "impl", "in", "let", "loop", "match", "mod", "move", "mut", "pub", "ref", "return", "self", "static", "struct", "super", "trait", "true", "type", "unsafe", "use", "where", "while", "async", "await", "dyn", "abstract", "become", "box", "do", "final", "macro", "override", "priv", "typeof", "unsized", "virtual", "yield", "try" };
    for (w) in words {
        if (w == s) {
            return true;
        }
    }
    return false;
}

fn rust_ident(s: str) -> std::string {
    if (rust_keyword(s)) {
        return fmt("r#{}", S(s));
    }
    return S(s);
}

// a type in the C functions' declarations (module raw sees the top level's types through super)
attach fn rust_ty(this: bind&, t: u32) -> std::string {
    val sh = this.shape_of(t) ?? return S("()");
    match (sh) {
        .VOID => { return S("()"); },
        .BOOL => { return S("bool"); },
        .INT(k) => { return S(k.name()); },
        .FLOAT(b) => {
            if (b == 32) {
                return S("f32");
            }
            return S("f64");
        },
        .CSTR => { return S("*const std::os::raw::c_char"); },
        .STR => { return S("VoltStr"); },
        .PTR(x) => {
            if (x == VOID) {
                return S("*mut std::os::raw::c_void");
            }
            match (this.shape_of(x) ?? shape::VOID) {
                .HANDLE(s) => { return fmt("*mut raw::{}", this.local(this.c.si(s).name)); },
                default => {},
            }
            var s = S("*mut ");
            s.append(this.rust_ty(x).as_str());
            return move s;
        },
        .STRUCT(s) => { return this.local(this.c.si(s).name); },
        .ENUM(e) => { return this.local(this.c.ei(e).name); },
        .CODE => { return S("u32"); },
        .RESULT(e, x) => { return this.result_name(t); },
        .ARRAY(elem, n) => { return fmt2("[{}; {}]", this.rust_ty(elem), unum(n)); },
        .FN(i) => { return this.rust_fn_ty(t, false); },
        .SLICE(x) => { return fmt("VoltSlice<{}>", this.rust_ty(x)); },
        .OPT(x) => { return fmt("VoltOpt<{}>", this.rust_ty(x)); },
        .HANDLE(s) => { return fmt("*mut raw::{}", this.local(this.c.si(s).name)); },
        .TEXT(x) => { return S("VoltText"); },
        .CLOSURE(i) => { return this.rust_fn_ty(t, true); },
    }
}

// an extern "C" fn type (with the caller's data first, for a closure)
attach fn rust_fn_ty(this: bind&, t: u32, user: bool) -> std::string {
    var s = S("extern \"C\" fn(");
    var ps: std::vec<u32> = {};
    var r = VOID;
    match (*this.c.t.get(t)) {
        .FN_PTR(xs&, rr, va) => {
            ps = copy *xs;
            r = rr;
        },
        .FN_VAL(xs&, rr) => {
            ps = copy *xs;
            r = rr;
        },
        default => {},
    }
    if (user) {
        s.append("*mut std::os::raw::c_void");
    }
    for (k) in 0..ps.len {
        if (k > 0 || user) {
            s.append(", ");
        }
        s.append(this.rust_ty(*ps.at(k)).as_str());
    }
    s.push(')');
    if (r != VOID) {
        s.append(" -> ");
        s.append(this.rust_ty(r).as_str());
    }
    return move s;
}

// a wrapper's parameter in Rust, and the C argument(s) it passes (pre: statements before the call)
attach fn rust_param(this: bind&, t: u32, name: str, ty: std::string&, arg: std::string&, pre: std::string&) -> void {
    val n = rust_ident(name);
    val h = this.lent_handle(t);
    if (h) {
        ty.append(fmt2("{}: &{}", copy n, this.local(this.c.si(h).name)).as_str());
        arg.append(fmt("{}.as_raw()", copy n).as_str());
        return;
    }
    match (this.shape_of(t) ?? shape::VOID) {
        .STR => {
            ty.append(fmt("{}: &str", copy n).as_str());
            arg.append(fmt("VoltStr::from({})", copy n).as_str());
        },
        .SLICE(x) => {
            ty.append(fmt2("{}: &mut [{}]", copy n, this.rust_ty(x)).as_str());
            arg.append(fmt("VoltSlice::from({})", copy n).as_str());
        },
        .OPT(x) => {
            ty.append(fmt2("{}: Option<{}>", copy n, this.rust_ty(x)).as_str());
            arg.append(fmt("VoltOpt::from({})", copy n).as_str());
        },
        .CLOSURE(i) => {
            match (*this.c.t.get(t)) {
                .FN_VAL(ps&, r) => {
                    var sig = S("dyn FnMut(");
                    var cps = S("u: *mut std::os::raw::c_void");
                    var cargs: std::string = {};
                    for (k) in 0..ps.len {
                        if (k > 0) {
                            sig.append(", ");
                            cargs.append(", ");
                        }
                        sig.append(this.rust_ty(*ps.at(k)).as_str());
                        cps.append(fmt2(", a{}: {}", unum(@cast<u64>(k)), this.rust_ty(*ps.at(k))).as_str());
                        cargs.append(fmt("a{}", unum(@cast<u64>(k))).as_str());
                    }
                    sig.push(')');
                    var ret: std::string = {};
                    if (r != VOID) {
                        ret = fmt(" -> {}", this.rust_ty(r));
                        sig.append(ret.as_str());
                    }
                    ty.append(fmt2("mut {}: &mut {}", copy n, copy sig).as_str());
                    // the C function calls the closure that the caller's data points at
                    pre.append(fmt4("    extern \"C\" fn call_{}({}){} {{\n        let f = unsafe {{ &mut *(u as *mut &mut {}) }};\n", S(name), move cps, copy ret, copy sig).as_str());
                    pre.append(fmt("        f({})\n    }\n", move cargs).as_str());
                    arg.append(fmt4("call_{}, &mut {} as *mut &mut {} as *mut std::os::raw::c_void", S(name), copy n, copy sig, S("")).as_str());
                },
                default => {},
            }
        },
        default => {
            match (*this.c.t.get(t)) {
                .REF(x) => {
                    ty.append(fmt2("{}: &mut {}", copy n, this.rust_ty(x)).as_str());
                    arg.append(fmt2("{} as *mut {}", copy n, this.rust_ty(x)).as_str());
                },
                default => {
                    ty.append(fmt2("{}: {}", copy n, this.rust_ty(t)).as_str());
                    arg.append(n.as_str());
                },
            }
        },
    }
}

// what a wrapper returns in Rust for a C result of type t
attach fn rust_ret(this: bind&, t: u32) -> std::string {
    match (this.shape_of(t) ?? shape::VOID) {
        .VOID => { return S("()"); },
        .STR => { return S("String"); },
        .TEXT(x) => { return S("String"); },
        .HANDLE(s) => { return this.local(this.c.si(s).name); },
        .OPT(x) => { return fmt("Option<{}>", this.rust_ty(x)); },
        .RESULT(e, x) => { return fmt("Result<{}, Error>", this.rust_ret(x)); },
        default => { return this.rust_ty(t); },
    }
}

attach fn rust_value(this: bind&, t: u32, r: str) -> std::string {
    match (this.shape_of(t) ?? shape::VOID) {
        .VOID => { return S("()"); },
        .STR => { return fmt("unsafe {{ {}.to_string() }}", S(r)); },
        .TEXT(x) => { return fmt("{}.take()", S(r)); },
        .HANDLE(s) => { return fmt2("{}::from_raw({})", this.local(this.c.si(s).name), S(r)); },
        .OPT(x) => { return fmt("{}.get()", S(r)); },
        default => { return S(r); },
    }
}

attach fn rust_body(this: bind&, f: u32, args: std::string, pre: std::string) -> std::string {
    val info = this.c.fi(f);
    var out = move pre;
    out.append(fmt3("    let r = unsafe {{ raw::{}({}) }};\n", S(info.c_name), move args, S("")).as_str());
    match (this.shape_of(info.ret) ?? shape::VOID) {
        .RESULT(e, x) => {
            out.append("    if r.error != 0 {\n        return Err(Error { code: r.error });\n    }\n");
            if (x == VOID) {
                out.append("    Ok(())\n");
            } else {
                out.append(fmt("    Ok({})\n", this.rust_value(x, "r.value")).as_str());
            }
        },
        .VOID => { out.append("    r\n"); },
        default => { out.append(fmt("    {}\n", this.rust_value(info.ret, "r")).as_str()); },
    }
    return move out;
}

attach fn rust_text(this: bind&) -> std::string {
    val ents = this.entries();
    var out: std::string = {};
    out.append(fmt("// {}: generated by voltc bindings; the Volt package for Rust. Link the library\n", S(this.pkg)).as_str());
    out.append("// yourself (-l NAME, or #[link] in a build script): shared or static. Module raw has the C\n// functions; the functions and types here wrap them (errors come back as Err(Error)).\n");
    out.append("#![allow(non_camel_case_types, non_upper_case_globals, non_snake_case, dead_code, unused_mut)]\n");
    if (this.uses_str) {
        out.append("\n/// a Volt str: bytes and a length (no terminator)\n#[repr(C)]\n#[derive(Clone, Copy, Debug)]\npub struct VoltStr {\n    pub ptr: *const u8,\n    pub len: usize,\n}\n\nimpl VoltStr {\n    pub fn from(s: &str) -> VoltStr {\n        VoltStr { ptr: s.as_ptr(), len: s.len() }\n    }\n    /// the bytes (valid as long as what the str points into)\n    pub unsafe fn bytes<'a>(self) -> &'a [u8] {\n        std::slice::from_raw_parts(self.ptr, self.len)\n    }\n    /// a copy of the text\n    pub unsafe fn to_string(self) -> String {\n        String::from_utf8_lossy(self.bytes()).into_owned()\n    }\n}\n");
    }
    if (this.texts.len > 0) {
        out.append("\n/// owned text a Volt function gave out: take() copies it into a String and frees it\n#[repr(C)]\npub struct VoltText {\n    pub ptr: *const u8,\n    pub len: usize,\n    pub owner: *mut std::os::raw::c_void,\n    pub drop: Option<extern \"C\" fn(*mut std::os::raw::c_void)>,\n}\n\nimpl VoltText {\n    pub fn take(self) -> String {\n        let s = unsafe { String::from_utf8_lossy(std::slice::from_raw_parts(self.ptr, self.len)).into_owned() };\n        if let Some(d) = self.drop {\n            d(self.owner);\n        }\n        s\n    }\n}\n");
    }
    if (this.slices.len > 0) {
        out.append("\n/// a Volt slice: elements and how many\n#[repr(C)]\n#[derive(Clone, Copy, Debug)]\npub struct VoltSlice<T> {\n    pub ptr: *mut T,\n    pub len: usize,\n}\n\nimpl<T> VoltSlice<T> {\n    pub fn from(s: &mut [T]) -> VoltSlice<T> {\n        VoltSlice { ptr: s.as_mut_ptr(), len: s.len() }\n    }\n}\n");
    }
    if (this.opts.len > 0) {
        out.append("\n/// a Volt optional: has says whether value is there\n#[repr(C)]\n#[derive(Clone, Copy, Debug)]\npub struct VoltOpt<T> {\n    pub value: T,\n    pub has: bool,\n}\n\nimpl<T> VoltOpt<T> {\n    pub fn from(o: Option<T>) -> VoltOpt<T> {\n        match o {\n            Some(value) => VoltOpt { value, has: true },\n            None => VoltOpt { value: unsafe { std::mem::zeroed() }, has: false },\n        }\n    }\n    pub fn get(self) -> Option<T> {\n        if self.has {\n            Some(self.value)\n        } else {\n            None\n        }\n    }\n}\n");
    }
    for (e&) in this.enums.items() {
        val info = this.c.ei(*e);
        out.append(fmt2("\n#[repr({})]\n#[derive(Clone, Copy, Debug, PartialEq, Eq)]\npub enum {} {{\n", S(info.tag.name()), this.local(info.name)).as_str());
        for (i) in 0..info.names.len {
            out.append(fmt2("    {} = {},\n", S(*info.names.at(i)), num(*info.values.at(i))).as_str());
        }
        out.append("}\n");
    }
    for (et&) in this.codes.items() {
        match (*this.c.t.get(*et)) {
            .ENUM(e) => {
                val info = this.c.ei(e);
                out.append(fmt2("\n/// the codes of error set {} (0 means no error)\npub struct {};\n", S(info.name), this.local(info.name)).as_str());
                out.append(fmt("impl {} {{\n", this.local(info.name)).as_str());
                for (i) in 0..info.names.len {
                    out.append(fmt2("    pub const {}: u32 = {};\n", S(*info.names.at(i)), num(*info.values.at(i))).as_str());
                }
                out.append("}\n");
            },
            default => {},
        }
    }
    if (this.codes.len > 0) {
        out.append("\n/// an error a Volt function returned: its code (see name())\n#[derive(Clone, Copy, Debug, PartialEq, Eq)]\npub struct Error {\n    pub code: u32,\n}\n\nimpl Error {\n    pub fn name(&self) -> &'static str {\n        match self.code {\n");
        for (c&) in this.all_codes().items() {
            out.append(fmt2("            {} => \"{}\",\n", num(c.code), S(c.name)).as_str());
        }
        out.append("            _ => \"error\",\n        }\n    }\n}\n\nimpl std::fmt::Display for Error {\n    fn fmt(&self, f: &mut std::fmt::Formatter) -> std::fmt::Result {\n        f.write_str(self.name())\n    }\n}\n\nimpl std::error::Error for Error {}\n");
    }
    for (s&) in this.structs.items() {
        val info = this.c.si(*s);
        out.append(fmt("\n#[repr(C)]\n#[derive(Clone, Copy, Debug)]\npub struct {} {{\n", this.local(info.name)).as_str());
        for (f&) in info.fields.items() {
            out.append(fmt2("    pub {}: {},\n", rust_ident(f.name), this.rust_ty(f.ty)).as_str());
        }
        out.append("}\n");
    }
    for (rt&) in this.results.items() {
        match (*this.c.t.get(*rt)) {
            .ERR_UNION(e, x) => {
                out.append(fmt2("\n/// {}: error is 0, or the error's code\n#[repr(C)]\npub struct {} {{\n    pub error: u32,\n", this.c.ty_name(*rt), this.result_name(*rt)).as_str());
                if (x != VOID) {
                    out.append(fmt("    pub value: {},\n", this.rust_ty(x)).as_str());
                }
                out.append("}\n");
            },
            default => {},
        }
    }
    // the C functions
    out.append("\n/// the C functions (the wrappers below are easier to use)\npub mod raw {\n    use super::*;\n");
    for (s&) in this.handles.items() {
        out.append(fmt("\n    /// export struct {}, behind a handle\n    #[repr(C)]\n    pub struct ", S(this.c.si(*s).name)).as_str());
        out.append(fmt("{} {\n        _private: [u8; 0],\n    }\n", this.local(this.c.si(*s).name)).as_str());
    }
    out.append("\n    extern \"C\" {\n");
    for (e&) in ents.items() {
        var args: std::string = {};
        val s = e.free_of;
        if (s) {
            args = fmt("it: *mut {}", this.local(this.c.si(s).name));
            out.append(fmt2("        pub fn {}({});\n", copy e.name, move args).as_str());
            continue;
        }
        val f = this.c.fi(e.f);
        for (p&) in f.params.items() {
            if (args.len() > 0) {
                args.append(", ");
            }
            args.append(fmt2("{}: {}", rust_ident(p.name), this.rust_ty(p.ty)).as_str());
            match (this.shape_of(p.ty) ?? shape::VOID) {
                .CLOSURE(i) => { args.append(fmt(", {}_user: *mut std::os::raw::c_void", S(p.name)).as_str()); },
                default => {},
            }
        }
        var ret: std::string = {};
        if (f.ret != VOID) {
            ret = fmt(" -> {}", this.rust_ty(f.ret));
        }
        out.append(fmt3("        pub fn {}({}){};\n", copy e.name, move args, move ret).as_str());
    }
    out.append("    }\n}\n");
    // a type per export struct: it owns its handle
    for (s&) in this.handles.items() {
        val cls = this.local(this.c.si(*s).name);
        out.append(fmt4("\n/// export struct {}: owns a handle, and frees it when dropped\npub struct {} {{\n    raw: *mut raw::{},\n}}\n\nimpl Drop for {} {{\n", S(this.c.si(*s).name), copy cls, copy cls, copy cls).as_str());
        out.append(fmt("    fn drop(&mut self) {\n        if !self.raw.is_null() {\n            unsafe { raw::{}(self.raw) }\n        }\n    }\n}\n", this.free_name(*s)).as_str());
        out.append(fmt3("\nimpl {} {{\n    /// takes ownership of a handle an export fn returned\n    pub fn from_raw(raw: *mut raw::{}) -> {} {{\n", copy cls, copy cls, copy cls).as_str());
        out.append(fmt2("        {} {{ raw }}\n    }}\n    pub fn as_raw(&self) -> *mut raw::{} {{\n        self.raw\n    }}\n", copy cls, copy cls).as_str());
        for (e&) in ents.items() {
            if (e.free_of != null) {
                continue;
            }
            val m = this.member_of(e.f, *s) ?? continue;
            val info = this.c.fi(e.f);
            var ps: std::string = {};
            var args: std::string = {};
            var pre: std::string = {};
            var first: usize = 0;
            if (info.params.len > 0 && this.lends(info.params.at(0).ty, *s)) {
                first = 1;
                ps.append("&self");
                args.append("self.raw");
            }
            for (k) in first..info.params.len {
                if (ps.len() > 0) {
                    ps.append(", ");
                }
                if (args.len() > 0) {
                    args.append(", ");
                }
                this.rust_param(info.params.at(k).ty, info.params.at(k).name, &ps, &args, &pre);
            }
            out.append(fmt3("    pub fn {}({}) -> {} {{\n", rust_ident(m), move ps, this.rust_ret(info.ret)).as_str());
            var body = this.rust_body(e.f, move args, move pre);
            out.append(indent(body.as_str()).as_str());
            out.append("    }\n");
        }
        out.append("}\n");
    }
    // the wrappers
    for (e&) in ents.items() {
        if (e.free_of != null || this.class_of(e.f) != null) {
            continue;
        }
        val info = this.c.fi(e.f);
        var ps: std::string = {};
        var args: std::string = {};
        var pre: std::string = {};
        for (p&) in info.params.items() {
            if (ps.len() > 0) {
                ps.append(", ");
                args.append(", ");
            }
            this.rust_param(p.ty, p.name, &ps, &args, &pre);
        }
        out.append(fmt3("\npub fn {}({}) -> {} {{\n", rust_ident(info.c_name), move ps, this.rust_ret(info.ret)).as_str());
        out.append(this.rust_body(e.f, move args, move pre).as_str());
        out.append("}\n");
    }
    return move out;
}

// ---------- Zig ----------

attach fn zig_ty(this: bind&, t: u32) -> std::string {
    val sh = this.shape_of(t) ?? return S("void");
    match (sh) {
        .VOID => { return S("void"); },
        .BOOL => { return S("bool"); },
        .INT(k) => { return S(k.name()); },
        .FLOAT(b) => {
            if (b == 32) {
                return S("f32");
            }
            return S("f64");
        },
        .CSTR => { return S("?[*:0]const u8"); },
        .STR => { return S("VoltStr"); },
        .PTR(x) => {
            if (x == VOID) {
                return S("?*anyopaque");
            }
            match (this.shape_of(x) ?? shape::VOID) {
                .HANDLE(s) => { return fmt("*raw.{}", this.local(this.c.si(s).name)); },
                default => {},
            }
            var s = S("*");
            s.append(this.zig_ty(x).as_str());
            return move s;
        },
        .STRUCT(s) => { return this.local(this.c.si(s).name); },
        .ENUM(e) => { return this.local(this.c.ei(e).name); },
        .CODE => { return S("u32"); },
        .RESULT(e, x) => { return this.result_name(t); },
        .ARRAY(elem, n) => { return fmt2("[{}]{}", unum(n), this.zig_ty(elem)); },
        .FN(i) => { return this.zig_fn_ty(t, false); },
        .SLICE(x) => { return fmt("VoltSlice({})", this.zig_ty(x)); },
        .OPT(x) => { return fmt("VoltOpt({})", this.zig_ty(x)); },
        .HANDLE(s) => { return fmt("*raw.{}", this.local(this.c.si(s).name)); },
        .TEXT(x) => { return S("VoltText"); },
        .CLOSURE(i) => { return this.zig_fn_ty(t, true); },
    }
}

attach fn zig_fn_ty(this: bind&, t: u32, user: bool) -> std::string {
    var s = S("*const fn (");
    var ps: std::vec<u32> = {};
    var r = VOID;
    match (*this.c.t.get(t)) {
        .FN_PTR(xs&, rr, va) => {
            ps = copy *xs;
            r = rr;
        },
        .FN_VAL(xs&, rr) => {
            ps = copy *xs;
            r = rr;
        },
        default => {},
    }
    if (user) {
        s.append("?*anyopaque");
    }
    for (k) in 0..ps.len {
        if (k > 0 || user) {
            s.append(", ");
        }
        s.append(this.zig_ty(*ps.at(k)).as_str());
    }
    s.append(") callconv(.c) ");
    s.append(this.zig_ty(r).as_str());
    return move s;
}

// Zig doesn't let a parameter shadow a declaration: a name the file declares gets a _
attach fn zig_name(this: bind&, name: str) -> std::string {
    var taken = name == "std" || name == "raw" || name == "Error" || name == "err_of" || name == "self" || name == "print";
    for (s&) in this.handles.items() {
        if (this.local(this.c.si(*s).name).as_str() == name) {
            taken = true;
        }
        for (f&) in this.exports().items() {
            val m = this.member_of(*f, *s) ?? continue;
            if (m == name) {
                taken = true;
            }
        }
    }
    for (s&) in this.structs.items() {
        if (this.local(this.c.si(*s).name).as_str() == name) {
            taken = true;
        }
    }
    for (e&) in this.enums.items() {
        if (this.local(this.c.ei(*e).name).as_str() == name) {
            taken = true;
        }
    }
    for (f&) in this.exports().items() {
        if (this.c.fi(*f).c_name == name) {
            taken = true;
        }
    }
    var n = S(name);
    if (taken) {
        n.push('_');
    }
    return move n;
}

attach fn zig_param(this: bind&, t: u32, name0: str, ty: std::string&, arg: std::string&, pre: std::string&) -> void {
    val zn = this.zig_name(name0);
    val name = zn.as_str();
    val h = this.lent_handle(t);
    if (h) {
        ty.append(fmt2("{}: {}", S(name), this.local(this.c.si(h).name)).as_str());
        arg.append(fmt("{}.raw", S(name)).as_str());
        return;
    }
    match (this.shape_of(t) ?? shape::VOID) {
        .STR => {
            ty.append(fmt("{}: []const u8", S(name)).as_str());
            arg.append(fmt("VoltStr.from({})", S(name)).as_str());
        },
        .SLICE(x) => {
            ty.append(fmt2("{}: []{}", S(name), this.zig_ty(x)).as_str());
            arg.append(fmt2("VoltSlice({}).from({})", this.zig_ty(x), S(name)).as_str());
        },
        .OPT(x) => {
            ty.append(fmt2("{}: ?{}", S(name), this.zig_ty(x)).as_str());
            arg.append(fmt2("VoltOpt({}).from({})", this.zig_ty(x), S(name)).as_str());
        },
        .CLOSURE(i) => {
            match (*this.c.t.get(t)) {
                .FN_VAL(ps&, r) => {
                    // context is passed to f with each call: f(context, args...)
                    var fps = fmt("@TypeOf({}_context)", S(name));
                    var cps = S("u: ?*anyopaque");
                    var cargs = fmt("ctx.*", S(""));
                    for (k) in 0..ps.len {
                        fps.append(", ");
                        fps.append(this.zig_ty(*ps.at(k)).as_str());
                        cps.append(fmt2(", a{}: {}", unum(@cast<u64>(k)), this.zig_ty(*ps.at(k))).as_str());
                        cargs.append(fmt(", a{}", unum(@cast<u64>(k))).as_str());
                    }
                    ty.append(fmt4("{}_context: anytype, comptime {}: fn ({}) {}", S(name), S(name), move fps, this.zig_ty(r)).as_str());
                    pre.append(fmt4("    const {}_call = struct {{\n        fn call({}) callconv(.c) {} {{\n            const ctx: *const @TypeOf({}_context) = @ptrCast(@alignCast(u));\n", S(name), move cps, this.zig_ty(r), S(name)).as_str());
                    pre.append(fmt2("            return {}({});\n        }}\n    }};\n", S(name), move cargs).as_str());
                    arg.append(fmt2("{}_call.call, @ptrCast(@constCast(&{}_context))", S(name), S(name)).as_str());
                },
                default => {},
            }
        },
        default => {
            ty.append(fmt2("{}: {}", S(name), this.zig_ty(t)).as_str());
            arg.append(name);
        },
    }
}

attach fn zig_ret(this: bind&, t: u32) -> std::string {
    match (this.shape_of(t) ?? shape::VOID) {
        .STR => { return S("[]const u8"); },
        .HANDLE(s) => { return this.local(this.c.si(s).name); },
        .OPT(x) => { return fmt("?{}", this.zig_ty(x)); },
        .RESULT(e, x) => { return fmt("Error!{}", this.zig_ret(x)); },
        default => { return this.zig_ty(t); },
    }
}

attach fn zig_value(this: bind&, t: u32, r: str) -> std::string {
    match (this.shape_of(t) ?? shape::VOID) {
        .STR => { return fmt("{}.slice()", S(r)); },
        .HANDLE(s) => { return fmt2("{}{{ .raw = {} }}", this.local(this.c.si(s).name), S(r)); },
        .OPT(x) => { return fmt("{}.get()", S(r)); },
        default => { return S(r); },
    }
}

attach fn zig_body(this: bind&, f: u32, args: std::string, pre: std::string) -> std::string {
    val info = this.c.fi(f);
    var out = move pre;
    if (info.ret == VOID) {
        out.append(fmt2("    raw.{}({});\n", S(info.c_name), move args).as_str());
        return move out;
    }
    out.append(fmt2("    const r = raw.{}({});\n", S(info.c_name), move args).as_str());
    match (this.shape_of(info.ret) ?? shape::VOID) {
        .RESULT(e, x) => {
            out.append("    if (r.@\"error\" != 0) return err_of(r.@\"error\");\n");
            if (x == VOID) {
                out.append("    return;\n");
            } else {
                out.append(fmt("    return {};\n", this.zig_value(x, "r.value")).as_str());
            }
        },
        default => { out.append(fmt("    return {};\n", this.zig_value(info.ret, "r")).as_str()); },
    }
    return move out;
}

attach fn zig_text(this: bind&) -> std::string {
    val ents = this.entries();
    var out: std::string = {};
    out.append(fmt("// {}: generated by voltc bindings; the Volt package for Zig. Struct raw has the C\n", S(this.pkg)).as_str());
    out.append("// functions; the functions and types here wrap them (errors come back as Error).\nconst std = @import(\"std\");\n");
    if (this.uses_str) {
        out.append("\n/// a Volt str: bytes and a length (no terminator)\npub const VoltStr = extern struct {\n    ptr: [*]const u8,\n    len: usize,\n    pub fn from(s: []const u8) VoltStr {\n        return .{ .ptr = s.ptr, .len = s.len };\n    }\n    pub fn slice(self: VoltStr) []const u8 {\n        return self.ptr[0..self.len];\n    }\n};\n");
    }
    if (this.texts.len > 0) {
        out.append("\n/// owned text a Volt function gave out: bytes(), then deinit() to free it\npub const VoltText = extern struct {\n    ptr: [*]const u8,\n    len: usize,\n    owner: ?*anyopaque,\n    drop: ?*const fn (?*anyopaque) callconv(.c) void,\n    pub fn bytes(self: VoltText) []const u8 {\n        return self.ptr[0..self.len];\n    }\n    pub fn deinit(self: VoltText) void {\n        if (self.drop) |d| d(self.owner);\n    }\n};\n");
    }
    if (this.slices.len > 0) {
        out.append("\n/// a Volt slice: elements and how many\npub fn VoltSlice(comptime T: type) type {\n    return extern struct {\n        ptr: [*]T,\n        len: usize,\n        pub fn from(s: []T) @This() {\n            return .{ .ptr = s.ptr, .len = s.len };\n        }\n    };\n}\n");
    }
    if (this.opts.len > 0) {
        out.append("\n/// a Volt optional: has says whether value is there\npub fn VoltOpt(comptime T: type) type {\n    return extern struct {\n        value: T,\n        has: bool,\n        pub fn from(o: ?T) @This() {\n            return if (o) |v| .{ .value = v, .has = true } else .{ .value = std.mem.zeroes(T), .has = false };\n        }\n        pub fn get(self: @This()) ?T {\n            return if (self.has) self.value else null;\n        }\n    };\n}\n");
    }
    for (e&) in this.enums.items() {
        val info = this.c.ei(*e);
        out.append(fmt2("\npub const {} = enum({}) {{\n", this.local(info.name), S(info.tag.name())).as_str());
        for (i) in 0..info.names.len {
            out.append(fmt2("    {} = {},\n", S(*info.names.at(i)), num(*info.values.at(i))).as_str());
        }
        out.append("};\n");
    }
    for (et&) in this.codes.items() {
        match (*this.c.t.get(*et)) {
            .ENUM(e) => {
                val info = this.c.ei(e);
                out.append(fmt2("\n/// the codes of error set {} (0 means no error)\npub const {} = struct {{\n", S(info.name), this.local(info.name)).as_str());
                for (i) in 0..info.names.len {
                    out.append(fmt2("    pub const {}: u32 = {};\n", S(*info.names.at(i)), num(*info.values.at(i))).as_str());
                }
                out.append("};\n");
            },
            default => {},
        }
    }
    if (this.codes.len > 0) {
        val codes = this.all_codes();
        out.append("\n/// the errors Volt functions return (Unknown: a code this file doesn't know)\npub const Error = error{");
        for (c&) in codes.items() {
            out.append(fmt(" {},", S(c.name)).as_str());
        }
        out.append(" Unknown };\n\npub fn err_of(code: u32) Error {\n    return switch (code) {\n");
        for (c&) in codes.items() {
            out.append(fmt2("        {} => error.{},\n", num(c.code), S(c.name)).as_str());
        }
        out.append("        else => error.Unknown,\n    };\n}\n");
    }
    for (s&) in this.structs.items() {
        val info = this.c.si(*s);
        out.append(fmt("\npub const {} = extern struct {{\n", this.local(info.name)).as_str());
        for (f&) in info.fields.items() {
            out.append(fmt2("    {}: {},\n", S(f.name), this.zig_ty(f.ty)).as_str());
        }
        out.append("};\n");
    }
    for (rt&) in this.results.items() {
        match (*this.c.t.get(*rt)) {
            .ERR_UNION(e, x) => {
                out.append(fmt2("\n/// {}: error is 0, or the error's code\npub const {} = extern struct {{\n    @\"error\": u32,\n", this.c.ty_name(*rt), this.result_name(*rt)).as_str());
                if (x != VOID) {
                    out.append(fmt("    value: {},\n", this.zig_ty(x)).as_str());
                }
                out.append("};\n");
            },
            default => {},
        }
    }
    out.append("\n/// the C functions (the wrappers below are easier to use)\npub const raw = struct {\n");
    for (s&) in this.handles.items() {
        out.append(fmt("    pub const {} = opaque {{}};\n", this.local(this.c.si(*s).name)).as_str());
    }
    for (e&) in ents.items() {
        var args: std::string = {};
        val s = e.free_of;
        if (s) {
            out.append(fmt2("    pub extern fn {}(it: *raw.{}) void;\n", copy e.name, this.local(this.c.si(s).name)).as_str());
            continue;
        }
        val f = this.c.fi(e.f);
        for (p&) in f.params.items() {
            if (args.len() > 0) {
                args.append(", ");
            }
            args.append(fmt2("{}: {}", S(p.name), this.zig_ty(p.ty)).as_str());
            match (this.shape_of(p.ty) ?? shape::VOID) {
                .CLOSURE(i) => { args.append(fmt(", {}_user: ?*anyopaque", S(p.name)).as_str()); },
                default => {},
            }
        }
        out.append(fmt3("    pub extern fn {}({}) {};\n", copy e.name, move args, this.zig_ty(f.ret)).as_str());
    }
    out.append("};\n");
    for (s&) in this.handles.items() {
        val cls = this.local(this.c.si(*s).name);
        out.append(fmt4("\n/// export struct {}: owns a handle; deinit() frees it\npub const {} = struct {{\n    raw: *raw.{},\n\n    pub fn deinit(self: {}) void {{\n", S(this.c.si(*s).name), copy cls, copy cls, copy cls).as_str());
        out.append(fmt("        raw.{}(self.raw);\n    }\n", this.free_name(*s)).as_str());
        for (e&) in ents.items() {
            if (e.free_of != null) {
                continue;
            }
            val m = this.member_of(e.f, *s) ?? continue;
            val info = this.c.fi(e.f);
            var ps: std::string = {};
            var args: std::string = {};
            var pre: std::string = {};
            var first: usize = 0;
            if (info.params.len > 0 && this.lends(info.params.at(0).ty, *s)) {
                first = 1;
                ps.append(fmt("self: {}", copy cls).as_str());
                args.append("self.raw");
            }
            for (k) in first..info.params.len {
                if (ps.len() > 0) {
                    ps.append(", ");
                }
                if (args.len() > 0) {
                    args.append(", ");
                }
                this.zig_param(info.params.at(k).ty, info.params.at(k).name, &ps, &args, &pre);
            }
            out.append(fmt3("\n    pub fn {}({}) {} {{\n", S(m), move ps, this.zig_ret(info.ret)).as_str());
            var body = this.zig_body(e.f, move args, move pre);
            out.append(indent(body.as_str()).as_str());
            out.append("    }\n");
        }
        out.append("};\n");
    }
    for (e&) in ents.items() {
        if (e.free_of != null || this.class_of(e.f) != null) {
            continue;
        }
        val info = this.c.fi(e.f);
        var ps: std::string = {};
        var args: std::string = {};
        var pre: std::string = {};
        for (p&) in info.params.items() {
            if (ps.len() > 0) {
                ps.append(", ");
                args.append(", ");
            }
            this.zig_param(p.ty, p.name, &ps, &args, &pre);
        }
        out.append(fmt3("\npub fn {}({}) {} {{\n", S(info.c_name), move ps, this.zig_ret(info.ret)).as_str());
        out.append(this.zig_body(e.f, move args, move pre).as_str());
        out.append("}\n");
    }
    return move out;
}

// each line of s, four spaces further in
fn indent(s: str) -> std::string {
    var out: std::string = {};
    var start = true;
    for (c) in s {
        if (start && c != '\n') {
            out.append("    ");
        }
        out.push(c);
        start = c == '\n';
    }
    return move out;
}

// ---------- Python ----------

attach fn py_ty(this: bind&, t: u32) -> std::string {
    val sh = this.shape_of(t) ?? return S("None");
    match (sh) {
        .VOID => { return S("None"); },
        .BOOL => { return S("ctypes.c_bool"); },
        .INT(k) => {
            if (k == int_ty::USIZE) {
                return S("ctypes.c_size_t");
            }
            if (k == int_ty::ISIZE) {
                return S("ctypes.c_ssize_t");
            }
            var s = S("ctypes.c_");
            if (!k.signed()) {
                s.push('u');
            }
            s.append("int");
            s.append_uint(@cast<u64>(k.bits()));
            return move s;
        },
        .FLOAT(b) => {
            if (b == 32) {
                return S("ctypes.c_float");
            }
            return S("ctypes.c_double");
        },
        .CSTR => { return S("ctypes.c_char_p"); },
        .STR => { return S("VoltStr"); },
        .PTR(x) => {
            if (x == VOID) {
                return S("ctypes.c_void_p");
            }
            match (this.shape_of(x) ?? shape::VOID) {
                .HANDLE(s) => { return S("ctypes.c_void_p"); },
                default => {},
            }
            return fmt("ctypes.POINTER({})", this.py_ty(x));
        },
        .STRUCT(s) => { return this.local(this.c.si(s).name); },
        .ENUM(e) => {
            val k = this.c.ei(e).tag;
            return this.py_ty(int_id(k));
        },
        .CODE => { return S("ctypes.c_uint32"); },
        .RESULT(e, x) => { return this.result_name(t); },
        .ARRAY(elem, n) => { return fmt2("({} * {})", this.py_ty(elem), unum(n)); },
        .FN(i) => { return this.py_fn_ty(t, false); },
        .SLICE(x) => { return this.made_name("slice", x, true); },
        .OPT(x) => { return this.made_name("opt", x, true); },
        .HANDLE(s) => { return S("ctypes.c_void_p"); },
        .TEXT(x) => { return S("VoltText"); },
        .CLOSURE(i) => { return this.py_fn_ty(t, true); },
    }
}

attach fn py_fn_ty(this: bind&, t: u32, user: bool) -> std::string {
    var ps: std::vec<u32> = {};
    var r = VOID;
    match (*this.c.t.get(t)) {
        .FN_PTR(xs&, rr, va) => {
            ps = copy *xs;
            r = rr;
        },
        .FN_VAL(xs&, rr) => {
            ps = copy *xs;
            r = rr;
        },
        default => {},
    }
    var s = S("ctypes.CFUNCTYPE(");
    s.append(this.py_ty(r).as_str());
    if (user) {
        s.append(", ctypes.c_void_p");
    }
    for (p&) in ps.items() {
        s.append(", ");
        s.append(this.py_ty(*p).as_str());
    }
    s.push(')');
    return move s;
}

// a wrapper's argument: what it passes to the C function for Python value name
attach fn py_arg(this: bind&, t: u32, name: str, conv: std::string&, pre: std::string&) -> void {
    if (this.lent_handle(t) != null) {
        conv.append(fmt("{}._h", S(name)).as_str());
        return;
    }
    match (this.shape_of(t) ?? shape::VOID) {
        .STR => { conv.append(fmt("_str({})", S(name)).as_str()); },
        .CSTR => { conv.append(fmt3("({}.encode() if isinstance({}, str) else {})", S(name), S(name), S(name)).as_str()); },
        .PTR(x) => {
            // a structure by reference (or a pointer as it is)
            conv.append(fmt3("(ctypes.byref({}) if isinstance({}, ctypes.Structure) else {})", S(name), S(name), S(name)).as_str());
        },
        .SLICE(x) => { conv.append(fmt3("_slice({}, {}, {})", this.made_name("slice", x, true), this.py_ty(x), S(name)).as_str()); },
        .OPT(x) => { conv.append(fmt2("_opt({}, {})", this.made_name("opt", x, true), S(name)).as_str()); },
        .CLOSURE(i) => {
            // the C function calls the Python one; kept alive by the local until the call returns
            pre.append(fmt3("    _{}_c = {}(lambda _u, *a: {}(*a))\n", S(name), this.py_fn_ty(t, true), S(name)).as_str());
            conv.append(fmt("_{}_c, None", S(name)).as_str());
        },
        default => { conv.append(name); },
    }
}

// the Python value of C result r (of type t)
attach fn py_value(this: bind&, t: u32, r: str) -> std::string {
    match (this.shape_of(t) ?? shape::VOID) {
        .STR => { return fmt("str({})", S(r)); },
        .CSTR => { return fmt3("({}.decode() if {} is not None else None)", S(r), S(r), S("")); },
        .TEXT(x) => { return fmt("_take({})", S(r)); },
        .HANDLE(s) => { return fmt2("{}._wrap({})", this.local(this.c.si(s).name), S(r)); },
        .OPT(x) => { return fmt2("({}.value if {}.has else None)", S(r), S(r)); },
        default => { return S(r); },
    }
}

attach fn py_body(this: bind&, f: u32, conv: std::string, pre: std::string) -> std::string {
    val info = this.c.fi(f);
    var out = move pre;
    out.append(fmt2("    r = _lib.{}({})\n", S(info.c_name), move conv).as_str());
    match (this.shape_of(info.ret) ?? shape::VOID) {
        .RESULT(e, x) => {
            out.append("    if r.error:\n        _raise(r.error)\n");
            if (x != VOID) {
                out.append(fmt("    return {}\n", this.py_value(x, "r.value")).as_str());
            }
        },
        .VOID => {},
        default => { out.append(fmt("    return {}\n", this.py_value(info.ret, "r")).as_str()); },
    }
    return move out;
}

attach fn py_text(this: bind&) -> std::string {
    val ents = this.entries();
    var out: std::string = {};
    out.append(fmt("# {}: generated by voltc bindings; the Volt package for Python (ctypes). It loads\n", S(this.pkg)).as_str());
    out.append(fmt2("# lib{}.so from $VOLT_{}_LIB, else from next to this file. Errors are raised as Error.\n", S(this.pkg), upper(this.pkg)).as_str());
    out.append("import ctypes\nimport os\n\n");
    out.append(fmt2("_lib = ctypes.CDLL(os.environ.get(\"VOLT_{}_LIB\") or os.path.join(os.path.dirname(os.path.abspath(__file__)), \"lib{}.so\"))\n", upper(this.pkg), S(this.pkg)).as_str());
    if (this.uses_str) {
        out.append("\n\nclass VoltStr(ctypes.Structure):\n    \"\"\"a Volt str: bytes and a length (no terminator)\"\"\"\n    _fields_ = [(\"ptr\", ctypes.c_void_p), (\"len\", ctypes.c_size_t)]\n\n    def __str__(self):\n        return ctypes.string_at(self.ptr, self.len).decode()\n\n\ndef _str(s):\n    b = s.encode() if isinstance(s, str) else bytes(s)\n    v = VoltStr(ctypes.cast(ctypes.c_char_p(b), ctypes.c_void_p), len(b))\n    v._keep = b\n    return v\n");
    }
    if (this.texts.len > 0) {
        out.append("\n\nclass VoltText(ctypes.Structure):\n    \"\"\"owned text a Volt function gave out (the wrappers copy it into a str and free it)\"\"\"\n    _fields_ = [(\"ptr\", ctypes.c_void_p), (\"len\", ctypes.c_size_t), (\"owner\", ctypes.c_void_p), (\"drop\", ctypes.CFUNCTYPE(None, ctypes.c_void_p))]\n\n\ndef _take(t):\n    s = ctypes.string_at(t.ptr, t.len).decode()\n    if t.drop:\n        t.drop(t.owner)\n    return s\n");
    }
    if (this.slices.len > 0) {
        out.append("\n\ndef _slice(cls, elem, xs):\n    arr = (elem * len(xs))(*xs)\n    v = cls(ctypes.cast(arr, ctypes.POINTER(elem)), len(xs))\n    v._keep = arr\n    return v\n");
    }
    if (this.opts.len > 0) {
        out.append("\n\ndef _opt(cls, x):\n    o = cls()\n    if x is not None:\n        o.value = x\n        o.has = True\n    return o\n");
    }
    for (e&) in this.enums.items() {
        val info = this.c.ei(*e);
        out.append(fmt("\n\nclass {}:\n", this.local(info.name)).as_str());
        for (i) in 0..info.names.len {
            out.append(fmt2("    {} = {}\n", S(*info.names.at(i)), num(*info.values.at(i))).as_str());
        }
    }
    if (this.codes.len > 0) {
        out.append("\n\nclass Error(Exception):\n    \"\"\"an error a Volt function returned: code, and name\"\"\"\n\n    def __init__(self, code):\n        self.code = code\n        self.name = _ERROR_NAMES.get(code, \"error\")\n        super().__init__(self.name)\n");
    }
    for (et&) in this.codes.items() {
        match (*this.c.t.get(*et)) {
            .ENUM(e) => {
                val info = this.c.ei(e);
                out.append(fmt2("\n\nclass {}(Error):\n    \"\"\"error set {}: its codes (0 means no error)\"\"\"\n", this.local(info.name), S(info.name)).as_str());
                for (i) in 0..info.names.len {
                    out.append(fmt2("    {} = {}\n", S(*info.names.at(i)), num(*info.values.at(i))).as_str());
                }
            },
            default => {},
        }
    }
    if (this.codes.len > 0) {
        val codes = this.all_codes();
        out.append("\n\n_ERROR_NAMES = {");
        for (c&) in codes.items() {
            out.append(fmt2("{}: \"{}\", ", num(c.code), S(c.name)).as_str());
        }
        out.append("}\n_ERROR_SETS = {");
        for (c&) in codes.items() {
            out.append(fmt2("{}: {}, ", num(c.code), copy c.set).as_str());
        }
        out.append("}\n\n\ndef _raise(code):\n    raise _ERROR_SETS.get(code, Error)(code)\n");
    }
    // the classes first, then their fields: structs may point at each other
    for (s&) in this.structs.items() {
        out.append(fmt("\n\nclass {}(ctypes.Structure):\n    pass\n", this.local(this.c.si(*s).name)).as_str());
    }
    for (x&) in this.slices.items() {
        out.append(fmt("\n\nclass {}(ctypes.Structure):\n    pass\n", this.made_name("slice", *x, true)).as_str());
    }
    for (x&) in this.opts.items() {
        out.append(fmt("\n\nclass {}(ctypes.Structure):\n    pass\n", this.made_name("opt", *x, true)).as_str());
    }
    for (rt&) in this.results.items() {
        out.append(fmt("\n\nclass {}(ctypes.Structure):\n    pass\n", this.result_name(*rt)).as_str());
    }
    out.append("\n");
    for (s&) in this.structs.items() {
        val info = this.c.si(*s);
        var fields: std::string = {};
        for (f&) in info.fields.items() {
            fields.append(fmt2("(\"{}\", {}), ", S(f.name), this.py_ty(f.ty)).as_str());
        }
        out.append(fmt2("\n{}._fields_ = [{}]", this.local(info.name), move fields).as_str());
    }
    for (x&) in this.slices.items() {
        out.append(fmt2("\n{}._fields_ = [(\"ptr\", ctypes.POINTER({})), (\"len\", ctypes.c_size_t)]", this.made_name("slice", *x, true), this.py_ty(*x)).as_str());
    }
    for (x&) in this.opts.items() {
        out.append(fmt2("\n{}._fields_ = [(\"value\", {}), (\"has\", ctypes.c_bool)]", this.made_name("opt", *x, true), this.py_ty(*x)).as_str());
    }
    for (rt&) in this.results.items() {
        match (*this.c.t.get(*rt)) {
            .ERR_UNION(e, x) => {
                var fields = S("(\"error\", ctypes.c_uint32)");
                if (x != VOID) {
                    fields.append(fmt(", (\"value\", {})", this.py_ty(x)).as_str());
                }
                out.append(fmt2("\n{}._fields_ = [{}]", this.result_name(*rt), move fields).as_str());
            },
            default => {},
        }
    }
    out.append("\n");
    // the C functions' types
    for (e&) in ents.items() {
        val s = e.free_of;
        if (s) {
            out.append(fmt2("\n_lib.{}.argtypes = [ctypes.c_void_p]\n_lib.{}.restype = None", copy e.name, copy e.name).as_str());
            continue;
        }
        val f = this.c.fi(e.f);
        var types: std::string = {};
        for (p&) in f.params.items() {
            if (types.len() > 0) {
                types.append(", ");
            }
            types.append(this.py_ty(p.ty).as_str());
            match (this.shape_of(p.ty) ?? shape::VOID) {
                .CLOSURE(i) => { types.append(", ctypes.c_void_p"); },
                default => {},
            }
        }
        out.append(fmt3("\n_lib.{}.argtypes = [{}]\n_lib.{}.restype = ", copy e.name, move types, copy e.name).as_str());
        out.append(this.py_ty(f.ret).as_str());
    }
    out.append("\n");
    // a class per export struct: it owns its handle (close(), a with block, or the garbage collector frees it)
    for (s&) in this.handles.items() {
        val cls = this.local(this.c.si(*s).name);
        out.append(fmt3("\n\nclass {}:\n    \"\"\"export struct {}: owns a handle; close() (or a with block) frees it\"\"\"\n\n    _h = None\n", copy cls, S(this.c.si(*s).name), S("")).as_str());
        out.append(fmt3("\n    @classmethod\n    def _wrap(cls, h):\n        o = cls.__new__(cls)\n        o._h = h\n        return o\n\n    def close(self):\n        if self._h:\n            _lib.{}(self._h)\n            self._h = None\n\n    def __enter__(self):\n        return self\n\n    def __exit__(self, *exc):\n        self.close()\n\n    def __del__(self):\n        self.close()\n", this.free_name(*s), S(""), S("")).as_str());
        for (e&) in ents.items() {
            if (e.free_of != null) {
                continue;
            }
            val m = this.member_of(e.f, *s) ?? continue;
            val info = this.c.fi(e.f);
            var names: std::string = {};
            var conv: std::string = {};
            var pre: std::string = {};
            var first: usize = 0;
            var is_method = info.params.len > 0 && this.lends(info.params.at(0).ty, *s);
            if (is_method) {
                first = 1;
                names.append("self");
                conv.append("self._h");
            }
            for (k) in first..info.params.len {
                if (names.len() > 0) {
                    names.append(", ");
                }
                if (conv.len() > 0) {
                    conv.append(", ");
                }
                names.append(info.params.at(k).name);
                this.py_arg(info.params.at(k).ty, info.params.at(k).name, &conv, &pre);
            }
            if (!is_method && m == "new") {
                // the constructor
                var ps = S("self");
                if (names.len() > 0) {
                    ps.append(", ");
                    ps.append(names.as_str());
                }
                out.append(fmt("\n    def __init__({}):\n", move ps).as_str());
                // __init__ keeps the handle the C function makes
                var body = move pre;
                body.append(fmt2("    r = _lib.{}({})\n", S(info.c_name), move conv).as_str());
                match (this.shape_of(info.ret) ?? shape::VOID) {
                    .RESULT(er, x) => { body.append("    if r.error:\n        _raise(r.error)\n    self._h = r.value\n"); },
                    default => { body.append("    self._h = r\n"); },
                }
                out.append(indent(body.as_str()).as_str());
                continue;
            }
            if (!is_method) {
                out.append("\n    @staticmethod");
            }
            out.append(fmt2("\n    def {}({}):\n", S(m), move names).as_str());
            var body = this.py_body(e.f, move conv, move pre);
            out.append(indent(body.as_str()).as_str());
        }
    }
    for (e&) in ents.items() {
        if (e.free_of != null || this.class_of(e.f) != null) {
            continue;
        }
        val info = this.c.fi(e.f);
        var names: std::string = {};
        var conv: std::string = {};
        var pre: std::string = {};
        for (p&) in info.params.items() {
            if (names.len() > 0) {
                names.append(", ");
                conv.append(", ");
            }
            names.append(p.name);
            this.py_arg(p.ty, p.name, &conv, &pre);
        }
        out.append(fmt2("\n\ndef {}({}):\n", S(info.c_name), move names).as_str());
        out.append(this.py_body(e.f, move conv, move pre).as_str());
    }
    return move out;
}

// ---------- JSON: the model every generator reads ----------

// A type in the JSON model: {"kind": ...} with what that kind needs. Kinds: void, bool, i8..u64,
// isize, usize, f32, f64, cstr, str, text (owned text: free it), pointer {to, nullable}, struct {name},
// enum {name}, error {set} (a u32 code), result {error, value}, array {of, len}, slice {of},
// optional {of}, handle {class, owned, nullable when lent}, function {params, returns} (an extern "C" fn pointer) and
// callback {params, returns} (a C function taking the caller's data first, then the data).
attach fn json_ty(this: bind&, t: u32) -> std::json::value {
    var o = std::json::object();
    val sh = this.shape_of(t) ?? shape::VOID;
    match (sh) {
        .VOID => { o.set("kind", std::json::string("void")); },
        .BOOL => { o.set("kind", std::json::string("bool")); },
        .INT(k) => { o.set("kind", std::json::string(k.name())); },
        .FLOAT(b) => {
            if (b == 32) {
                o.set("kind", std::json::string("f32"));
            } else {
                o.set("kind", std::json::string("f64"));
            }
        },
        .CSTR => { o.set("kind", std::json::string("cstr")); },
        .STR => { o.set("kind", std::json::string("str")); },
        .PTR(x) => {
            val h = this.lent_handle(t);
            if (h) {
                o.set("kind", std::json::string("handle"));
                o.set("class", std::json::string(this.local(this.c.si(h).name).as_str()));
                o.set("owned", std::json::boolean(false));
            } else {
                o.set("kind", std::json::string("pointer"));
                o.set("to", this.json_ty(x));
            }
            // a reference (T&) is never null; T* and T&? can be
            var nullable = true;
            match (*this.c.t.get(t)) {
                .REF(y) => { nullable = false; },
                default => {},
            }
            o.set("nullable", std::json::boolean(nullable));
        },
        .STRUCT(s) => {
            o.set("kind", std::json::string("struct"));
            o.set("name", std::json::string(this.local(this.c.si(s).name).as_str()));
        },
        .ENUM(e) => {
            o.set("kind", std::json::string("enum"));
            o.set("name", std::json::string(this.local(this.c.ei(e).name).as_str()));
        },
        .CODE => {
            o.set("kind", std::json::string("error"));
            o.set("set", std::json::string(this.short(t).as_str()));
        },
        .RESULT(e, x) => {
            o.set("kind", std::json::string("result"));
            o.set("error", std::json::string(this.short(e).as_str()));
            o.set("value", this.json_ty(x));
            o.set("c_name", std::json::string(this.c_named(this.result_name(t).as_str(), false).as_str()));
        },
        .ARRAY(elem, n) => {
            o.set("kind", std::json::string("array"));
            o.set("of", this.json_ty(elem));
            o.set("len", std::json::number(@cast<f64>(n)));
        },
        .FN(i) => {
            o.set("kind", std::json::string("function"));
            this.json_sig(t, &o);
        },
        .SLICE(x) => {
            o.set("kind", std::json::string("slice"));
            o.set("of", this.json_ty(x));
        },
        .OPT(x) => {
            o.set("kind", std::json::string("optional"));
            o.set("of", this.json_ty(x));
        },
        .HANDLE(s) => {
            o.set("kind", std::json::string("handle"));
            o.set("class", std::json::string(this.local(this.c.si(s).name).as_str()));
            o.set("owned", std::json::boolean(true));
        },
        .TEXT(x) => { o.set("kind", std::json::string("text")); },
        .CLOSURE(i) => {
            o.set("kind", std::json::string("callback"));
            this.json_sig(t, &o);
        },
    }
    return move o;
}

// a fn type's params and returns, into o
attach fn json_sig(this: bind&, t: u32, o: std::json::value&) -> void {
    var ps = std::json::array();
    var r = VOID;
    match (*this.c.t.get(t)) {
        .FN_PTR(xs&, rr, va) => {
            for (p&) in xs.items() {
                ps.add(this.json_ty(*p));
            }
            r = rr;
        },
        .FN_VAL(xs&, rr) => {
            for (p&) in xs.items() {
                ps.add(this.json_ty(*p));
            }
            r = rr;
        },
        default => {},
    }
    o.set("params", move ps);
    o.set("returns", this.json_ty(r));
}

attach fn json_text(this: bind&) -> std::string {
    val ents = this.entries();
    var out = std::json::object();
    out.set("package", std::json::string(this.pkg));
    out.set("version", std::json::number(1.0));
    var types = std::json::array();
    for (s&) in this.structs.items() {
        val info = this.c.si(*s);
        var o = std::json::object();
        o.set("kind", std::json::string("struct"));
        o.set("name", std::json::string(this.local(info.name).as_str()));
        o.set("c_name", std::json::string(this.c_named(info.name, false).as_str()));
        var fields = std::json::array();
        for (f&) in info.fields.items() {
            var fo = std::json::object();
            fo.set("name", std::json::string(f.name));
            fo.set("type", this.json_ty(f.ty));
            fields.add(move fo);
        }
        o.set("fields", move fields);
        types.add(move o);
    }
    for (e&) in this.enums.items() {
        val info = this.c.ei(*e);
        var o = std::json::object();
        o.set("kind", std::json::string("enum"));
        o.set("name", std::json::string(this.local(info.name).as_str()));
        o.set("c_name", std::json::string(this.c_named(info.name, false).as_str()));
        o.set("tag", std::json::string(info.tag.name()));
        var vals = std::json::array();
        for (i) in 0..info.names.len {
            var v = std::json::object();
            v.set("name", std::json::string(*info.names.at(i)));
            v.set("value", std::json::number(@cast<f64>(*info.values.at(i))));
            vals.add(move v);
        }
        o.set("values", move vals);
        types.add(move o);
    }
    for (et&) in this.codes.items() {
        match (*this.c.t.get(*et)) {
            .ENUM(e) => {
                val info = this.c.ei(e);
                var o = std::json::object();
                o.set("kind", std::json::string("error_set"));
                o.set("name", std::json::string(this.local(info.name).as_str()));
                var vals = std::json::array();
                for (i) in 0..info.names.len {
                    var v = std::json::object();
                    v.set("name", std::json::string(*info.names.at(i)));
                    v.set("code", std::json::number(@cast<f64>(*info.values.at(i))));
                    vals.add(move v);
                }
                o.set("codes", move vals);
                types.add(move o);
            },
            default => {},
        }
    }
    for (s&) in this.handles.items() {
        var o = std::json::object();
        o.set("kind", std::json::string("class"));
        o.set("name", std::json::string(this.local(this.c.si(*s).name).as_str()));
        o.set("c_name", std::json::string(this.c_named(this.c.si(*s).name, false).as_str()));
        o.set("free", std::json::string(this.free_name(*s).as_str()));
        types.add(move o);
    }
    out.set("types", move types);
    var fns = std::json::array();
    for (e&) in ents.items() {
        var o = std::json::object();
        o.set("name", std::json::string(e.name.as_str()));
        var ps = std::json::array();
        val s = e.free_of;
        if (s) {
            var p = std::json::object();
            p.set("name", std::json::string("it"));
            var h = std::json::object();
            h.set("kind", std::json::string("handle"));
            h.set("class", std::json::string(this.local(this.c.si(s).name).as_str()));
            h.set("owned", std::json::boolean(true));
            p.set("type", move h);
            ps.add(move p);
            o.set("params", move ps);
            var v = std::json::object();
            v.set("kind", std::json::string("void"));
            o.set("returns", move v);
            o.set("frees", std::json::string(this.local(this.c.si(s).name).as_str()));
            fns.add(move o);
            continue;
        }
        val info = this.c.fi(e.f);
        for (p&) in info.params.items() {
            var po = std::json::object();
            po.set("name", std::json::string(p.name));
            po.set("type", this.json_ty(p.ty));
            ps.add(move po);
        }
        o.set("params", move ps);
        o.set("returns", this.json_ty(info.ret));
        val cls = this.class_of(e.f);
        if (cls) {
            o.set("class", std::json::string(this.local(this.c.si(cls).name).as_str()));
            o.set("method", std::json::string(this.member_of(e.f, cls) ?? ""));
            o.set("static", std::json::boolean(!(info.params.len > 0 && this.lends(info.params.at(0).ty, cls))));
        }
        // its doc comment, for generators that copy it
        val sp = this.c.dl(info.decl).item.span;
        o.set("doc", std::json::string(doc_above(this.c.files.at(sp.file).text, @cast<usize>(sp.lo)).as_str()));
        fns.add(move o);
    }
    out.set("functions", move fns);
    var text = out.text();
    text.push('\n');
    return move text;
}

// ---------- JavaScript: a Node-API addon (Node.js, Bun), its loader and TypeScript types ----------

// the C name a struct's JS converters use
attach fn node_sname(this: bind&, s: u32) -> std::string {
    return this.local(this.c.si(s).name);
}

// can a value of type t come from JS (or go to it) as a plain value: numbers, bool, enums, error
// codes and structs of those
attach fn node_simple(this: bind&, t: u32) -> bool {
    match (this.shape_of(t) ?? shape::VOID) {
        .BOOL => { return true; },
        .INT(k) => { return true; },
        .FLOAT(b) => { return true; },
        .ENUM(e) => { return true; },
        .CODE => { return true; },
        .STRUCT(s) => {
            for (f&) in this.c.si(s).fields.items() {
                if (!this.node_simple(f.ty)) {
                    return false;
                }
            }
            return true;
        },
        default => { return false; },
    }
}

// C statements that read JS value js into C lvalue c (of type t); they `goto fail` with a JS
// exception thrown when js doesn't fit. Simple types only (node_simple)
attach fn node_get_simple(this: bind&, t: u32, js: str, c: str) -> std::string {
    match (this.shape_of(t) ?? shape::VOID) {
        .BOOL => { return fmt2("if (!vn_bool(env, {}, &{})) { goto fail; }", S(js), S(c)); },
        .FLOAT(b) => { return fmt3("{{ double v_; if (!vn_f64(env, {}, &v_)) { goto fail; } {} = ({})v_; }}", S(js), S(c), this.c_prim(t, false)); },
        .INT(k) => {
            if (k.signed()) {
                return fmt4("{{ int64_t v_; if (!vn_i64(env, {}, &v_)) {{ goto fail; }}{} {} = ({})v_; }}", S(js), node_range(k), S(c), this.c_prim(t, false));
            }
            return fmt4("{{ uint64_t v_; if (!vn_u64(env, {}, &v_)) {{ goto fail; }}{} {} = ({})v_; }}", S(js), node_range(k), S(c), this.c_prim(t, false));
        },
        .ENUM(e) => { return fmt4("{{ uint64_t v_; if (!vn_u64(env, {}, &v_)) {{ goto fail; }}{} {} = ({})v_; }}", S(js), node_range(this.c.ei(e).tag), S(c), this.c_prim(t, false)); },
        .CODE => { return fmt3("{{ uint64_t v_; if (!vn_u64(env, {}, &v_)) {{ goto fail; }}{} {} = (uint32_t)v_; }}", S(js), node_range(int_ty::U32), S(c)); },
        .STRUCT(s) => { return fmt3("if (!vn_get_{}(env, {}, &{})) { goto fail; }", this.node_sname(s), S(js), S(c)); },
        default => { return S("goto fail;"); },
    }
}

// the check that an integer read as v_ (64 bits) fits a narrower C type
fn node_range(k: int_ty) -> std::string {
    var lo = "";
    var hi = "";
    if (k == int_ty::I8) {
        lo = "INT8_MIN";
        hi = "INT8_MAX";
    } else if (k == int_ty::I16) {
        lo = "INT16_MIN";
        hi = "INT16_MAX";
    } else if (k == int_ty::I32) {
        lo = "INT32_MIN";
        hi = "INT32_MAX";
    } else if (k == int_ty::U8) {
        hi = "UINT8_MAX";
    } else if (k == int_ty::U16) {
        hi = "UINT16_MAX";
    } else if (k == int_ty::U32) {
        hi = "UINT32_MAX";
    } else {
        return {};
    }
    if (lo.len > 0) {
        return fmt2(" if (v_ < {} || v_ > {}) {{ vn_throw_range(env); goto fail; }}", S(lo), S(hi));
    }
    return fmt(" if (v_ > {}) { vn_throw_range(env); goto fail; }", S(hi));
}

// a C expression making the JS value of simple C value c (of type t)
attach fn node_put_simple(this: bind&, t: u32, c: str) -> std::string {
    match (this.shape_of(t) ?? shape::VOID) {
        .BOOL => { return fmt("vn_from_bool(env, {})", S(c)); },
        .STRUCT(s) => { return fmt2("vn_new_{}(env, &{})", this.node_sname(s), S(c)); },
        default => { return fmt("vn_num(env, (double)({}))", S(c)); },
    }
}

// one argument of an export fn: its C local(s) (decl), the statements that fill them from js
// (get), what the call passes (pass), what runs after the call (after: writing back into JS
// objects and arrays) and what frees its temporaries (cleanup)
struct node_arg {
    decl: std::string = {};
    get: std::string = {};
    pass: std::string = {};
    after: std::string = {};
    cleanup: std::string = {};
}

attach fn node_arg_of(this: bind&, t: u32, js: str, c: str, a: node_arg&) -> compile_error!void {
    if (this.node_simple(t)) {
        a.decl = fmt2("{} {};", this.c_prim(t, false), S(c));
        a.get = this.node_get_simple(t, js, c);
        a.pass = S(c);
        return;
    }
    val h = this.lent_handle(t);
    if (h) {
        a.decl = fmt2("{}{} = NULL;", spaced(this.handle_c(h, false)), S(c));
        a.get = fmt4("if (!vn_unwrap(env, {}, &vn_tag_{}, (void **)&{}, \"{}\")) { goto fail; }", S(js), this.node_sname(h), S(c), this.node_sname(h));
        a.pass = S(c);
        return;
    }
    match (this.shape_of(t) ?? shape::VOID) {
        .STR => {
            a.decl = fmt2("volt_str {}; char *{}_buf = NULL;", S(c), S(c));
            a.get = fmt3("if (!vn_str(env, {}, &{}, &{}_buf)) { goto fail; }", S(js), S(c), S(c));
            a.pass = S(c);
            a.cleanup = fmt("free({}_buf);", S(c));
        },
        .CSTR => {
            a.decl = fmt2("const char *{} = NULL; char *{}_buf = NULL;", S(c), S(c));
            a.get = fmt3("if (!vn_cstr(env, {}, &{}, &{}_buf)) { goto fail; }", S(js), S(c), S(c));
            a.pass = S(c);
            a.cleanup = fmt("free({}_buf);", S(c));
        },
        .PTR(x) => {
            if (x != VOID && this.node_simple(x)) {
                // a struct (or number) by reference: a copy goes in, and what Volt changed comes back
                a.decl = fmt2("{} {}_val;", this.c_prim(x, false), S(c));
                var nullable = true;
                match (*this.c.t.get(t)) {
                    .REF(y) => { nullable = false; },
                    default => {},
                }
                if (nullable) {
                    a.decl.append(fmt(" bool {}_null = false;", S(c)).as_str());
                    a.get = fmt2("{}_null = vn_is_nullish(env, {});", S(c), S(js));
                    a.get.append(fmt2(" if (!{}_null) {{ {} }}", S(c), this.node_get_simple(x, js, fmt("{}_val", S(c)).as_str())).as_str());
                    a.pass = fmt2("({}_null ? NULL : &{}_val)", S(c), S(c));
                    a.after = fmt3("if (!{}_null) vn_set_{}(env, {}, ", S(c), this.node_ptr_set_name(x), S(js));
                    a.after.append(fmt("&{}_val);", S(c)).as_str());
                } else {
                    a.get = this.node_get_simple(x, js, fmt("{}_val", S(c)).as_str());
                    a.pass = fmt("&{}_val", S(c));
                    a.after = fmt3("vn_set_{}(env, {}, &{}_val);", this.node_ptr_set_name(x), S(js), S(c));
                }
                return;
            }
            // anything else behind a pointer: an External from another call
            a.decl = fmt2("{}{} = NULL;", spaced(this.c_prim(t, false)), S(c));
            a.get = fmt2("if (!vn_external(env, {}, (void **)&{})) { goto fail; }", S(js), S(c));
            a.pass = S(c);
        },
        .SLICE(x) => {
            if (!this.node_simple(x)) {
                return fail(NO_SPAN, fmt("a slice of {} can't come from JavaScript (numbers, bool, enums and structs of those can)", this.c.ty_name(x)));
            }
            val et = this.c_prim(x, false);
            a.decl = fmt3("{} {}; {} *", this.c_prim(t, false), S(c), copy et);
            a.decl.append(fmt2("{}_buf = NULL; uint32_t {}_n = 0;", S(c), S(c)).as_str());
            a.get = fmt3("if (!vn_array(env, {}, &{}_n)) { goto fail; } {}_buf = ", S(js), S(c), S(c));
            a.get.append(fmt3("malloc(sizeof({}) * ({}_n ? {}_n : 1));", copy et, S(c), S(c)).as_str());
            a.get.append(fmt(" if (!{}_buf) {{ vn_throw(env, \"out of memory\"); goto fail; }}", S(c)).as_str());
            a.get.append(fmt3(" for (uint32_t i = 0; i < {}_n; i++) {{ napi_value e; napi_get_element(env, {}, i, &e); {} }}", S(c), S(js), this.node_get_simple(x, "e", fmt("{}_buf[i]", S(c)).as_str())).as_str());
            a.get.append(fmt4(" {}.ptr = {}_buf; {}.len = {}_n;", S(c), S(c), S(c), S(c)).as_str());
            a.pass = S(c);
            // what Volt wrote into the elements comes back
            a.after = fmt4("for (uint32_t i = 0; i < {}_n; i++) napi_set_element(env, {}, i, {});", S(c), S(js), this.node_put_simple(x, fmt("{}_buf[i]", S(c)).as_str()), S(""));
            a.cleanup = fmt("free({}_buf);", S(c));
        },
        .OPT(x) => {
            if (!this.node_simple(x)) {
                return fail(NO_SPAN, fmt("an optional {} can't come from JavaScript (numbers, bool, enums and structs of those can)", this.c.ty_name(x)));
            }
            a.decl = fmt2("{} {};", this.c_prim(t, false), S(c));
            a.get = fmt4("memset(&{}, 0, sizeof {}); if (!vn_is_nullish(env, {})) {{ {}.has = true; ", S(c), S(c), S(js), S(c));
            a.get.append(fmt("{} }", this.node_get_simple(x, js, fmt("{}.value", S(c)).as_str())).as_str());
            a.pass = S(c);
        },
        .CLOSURE(i) => {
            a.decl = fmt("struct vn_cb {}_cb;", S(c));
            a.get = fmt4("if (!vn_function(env, {})) { goto fail; } {}_cb.env = env; {}_cb.fn = {};", S(js), S(c), S(c), S(js));
            a.pass = fmt3("vn_cb{}, &{}_cb", unum(@cast<u64>(i)), S(c), S(""));
        },
        default => {
            return fail(NO_SPAN, fmt("{} can't come from JavaScript", this.c.ty_name(t)));
        },
    }
    return;
}

// which vn_set_ writes a C value back into a JS object (a struct's fields)
attach fn node_ptr_set_name(this: bind&, x: u32) -> std::string {
    match (this.shape_of(x) ?? shape::VOID) {
        .STRUCT(s) => { return this.node_sname(s); },
        default => { return S("none"); },
    }
}

// C statements that turn C result r (of type t) into JS value `result`; an error result throws
attach fn node_result(this: bind&, t: u32, r: str) -> compile_error!std::string {
    if (t == VOID) {
        return S("napi_get_undefined(env, &result);");
    }
    if (this.node_simple(t)) {
        return fmt("result = {};", this.node_put_simple(t, r));
    }
    match (this.shape_of(t) ?? shape::VOID) {
        .STR => { return fmt3("result = vn_from_str(env, {}.ptr, {}.len);", S(r), S(r), S("")); },
        .CSTR => { return fmt("result = vn_from_cstr(env, {});", S(r)); },
        .TEXT(x) => { return fmt3("result = vn_from_str(env, {}.ptr, {}.len); volt_text_free({});", S(r), S(r), S(r)); },
        .HANDLE(s) => { return fmt2("result = vn_wrap_{}(env, {});", this.node_sname(s), S(r)); },
        .OPT(x) => {
            if (!this.node_simple(x)) {
                return fail(NO_SPAN, fmt("an optional {} can't go to JavaScript", this.c.ty_name(x)));
            }
            return fmt3("if ({}.has) result = {}; else napi_get_null(env, &result);", S(r), this.node_put_simple(x, fmt("{}.value", S(r)).as_str()), S(""));
        },
        .SLICE(x) => {
            if (!this.node_simple(x)) {
                return fail(NO_SPAN, fmt("a slice of {} can't go to JavaScript", this.c.ty_name(x)));
            }
            return fmt4("napi_create_array_with_length(env, {}.len, &result); for (size_t i = 0; i < {}.len; i++) napi_set_element(env, result, (uint32_t)i, {});", S(r), S(r), this.node_put_simple(x, fmt("{}.ptr[i]", S(r)).as_str()), S(""));
        },
        .RESULT(e, x) => {
            var out = fmt("if ({}.error != 0) { vn_throw_code(env, ", S(r));
            out.append(fmt("{}.error); goto fail; } ", S(r)).as_str());
            if (x == VOID) {
                out.append("napi_get_undefined(env, &result);");
            } else {
                out.append((try this.node_result(x, fmt("{}.value", S(r)).as_str())).as_str());
            }
            return move out;
        },
        .PTR(x) => { return fmt("result = vn_from_external(env, (void *){});", S(r)); },
        default => { return fail(NO_SPAN, fmt("{} can't go to JavaScript", this.c.ty_name(t))); },
    }
}

// the C function behind one JS function (self: the export struct a method's this is, if any)
attach fn node_fn(this: bind&, f: u32, wname: str, self_class: u32?, out: std::string&) -> compile_error!void {
    val info = this.c.fi(f);
    var first: usize = 0;
    var decls: std::string = {};
    var gets: std::string = {};
    var passes: std::string = {};
    var afters: std::string = {};
    var cleanups: std::string = {};
    val sc = self_class;
    if (sc) {
        first = 1;
        decls.append(fmt2("    {}p_self = NULL;\n", spaced(this.handle_c(sc, false)), S("")).as_str());
        gets.append(fmt2("    if (!vn_unwrap(env, self, &vn_tag_{}, (void **)&p_self, \"{}\")) { goto fail; }\n", this.node_sname(sc), this.node_sname(sc)).as_str());
        passes.append("p_self");
    }
    val n = info.params.len - first;
    var required: usize = 0;
    for (k) in first..info.params.len {
        val p = info.params.at(k);
        var a: node_arg = {};
        val js = fmt("argv[{}]", unum(@cast<u64>(k - first)));
        val cname = fmt("p_{}", S(p.name));
        try this.node_arg_of(p.ty, js.as_str(), cname.as_str(), &a);
        decls.append(fmt("    {}\n", copy a.decl).as_str());
        gets.append(fmt("    {}\n", copy a.get).as_str());
        if (passes.len() > 0) {
            passes.append(", ");
        }
        passes.append(a.pass.as_str());
        if (a.after.len() > 0) {
            afters.append(fmt("        {}\n", copy a.after).as_str());
        }
        if (a.cleanup.len() > 0) {
            cleanups.append(fmt("    {}\n", copy a.cleanup).as_str());
        }
        match (this.shape_of(p.ty) ?? shape::VOID) {
            .OPT(x) => {},
            default => { required = k - first + 1; },
        }
    }
    var argn = n;
    if (argn == 0) {
        argn = 1;
    }
    out.append(fmt3("\nstatic napi_value {}(napi_env env, napi_callback_info info) {{\n    size_t argc = {};\n    napi_value argv[{}], self = NULL, result = NULL;\n", S(wname), unum(@cast<u64>(n)), unum(@cast<u64>(argn))).as_str());
    out.append(decls.as_str());
    out.append("    if (napi_get_cb_info(env, info, &argc, argv, &self, NULL) != napi_ok) {\n        return NULL;\n    }\n");
    if (required > 0) {
        out.append(fmt3("    if (argc < {}) {{\n        napi_throw_type_error(env, NULL, \"{} takes {} arguments\");\n        return NULL;\n    }}\n", unum(@cast<u64>(required)), S(info.c_name), unum(@cast<u64>(required))).as_str());
    }
    out.append(gets.as_str());
    out.append("    if (0) {\n        goto fail;\n    }\n    {\n");
    val call = fmt2("{}({})", S(info.c_name), move passes);
    if (info.ret == VOID) {
        out.append(fmt("        {};\n", move call).as_str());
    } else {
        out.append(fmt2("        {}r = {};\n", spaced(this.c_prim(info.ret, false)), move call).as_str());
    }
    // the result first: an error throws (goto fail) before anything is written back
    out.append(fmt("        {}\n", try this.node_result(info.ret, "r")).as_str());
    out.append(afters.as_str());
    out.append("    }\nfail:\n");
    out.append(cleanups.as_str());
    out.append("    return result;\n}\n");
    return;
}

// a stable 128-bit tag for export struct s, so a method can check what its this is
attach fn node_tag(this: bind&, s: u32) -> std::string {
    var name = S(this.pkg);
    name.append("::");
    name.append(this.node_sname(s).as_str());
    val a = fnv64(name.as_str());
    name.append("#");
    val b = fnv64(name.as_str());
    return fmt2("{{0x{}ULL, 0x{}ULL}}", hex_u64(a), hex_u64(b));
}

fn fnv64(s: str) -> u64 {
    var h: u64 = 14695981039346656037;
    for (c) in s {
        h = (h ^ @cast<u64>(c)) *% 1099511628211;
    }
    return h;
}

fn hex_u64(v: u64) -> std::string {
    val digits = "0123456789abcdef";
    var out: std::string = {};
    var i: u64 = 16;
    while (i > 0) {
        i -= 1;
        out.push(digits[@cast<usize>((v >> (i * 4)) & 15)]);
    }
    return move out;
}

attach fn node_text(this: bind&) -> compile_error!std::string {
    val ents = this.entries();
    var out: std::string = {};
    out.append(fmt("// {}: generated by voltc bindings; a Node-API addon (Node.js, Bun) for the Volt package\n", S(this.pkg)).as_str());
    out.append(fmt3("// {}. Build it against the library and node's headers:\n//   cc -shared -fPIC -I<node's include/node> {}_node.c -L. -l{} -o ", S(this.pkg), S(this.pkg), S(this.pkg)).as_str());
    out.append(fmt("{}.node\n// then require it (or the loader voltc bindings --lang js writes).\n#include <node_api.h>\n#include <stdio.h>\n#include <stdlib.h>\n#include <string.h>\n\n", S(this.pkg)).as_str());
    out.append(this.c_text().as_str());
    out.append("\n// ---------- conversions ----------\n\n");
    out.append("// throw a TypeError, unless something already threw; always 0\nstatic inline int vn_throw(napi_env env, const char *what) {\n    bool pending = false;\n    napi_is_exception_pending(env, &pending);\n    if (!pending) {\n        napi_throw_type_error(env, NULL, what);\n    }\n    return 0;\n}\n\n");
    out.append("static inline void vn_throw_range(napi_env env) {\n    napi_throw_range_error(env, NULL, \"the number doesn't fit the parameter's type\");\n}\n\n");
    out.append("static inline int vn_is_nullish(napi_env env, napi_value v) {\n    napi_valuetype t = napi_undefined;\n    napi_typeof(env, v, &t);\n    return t == napi_undefined || t == napi_null;\n}\n\n");
    out.append("static inline int vn_bool(napi_env env, napi_value v, bool *out) {\n    return napi_get_value_bool(env, v, out) == napi_ok || vn_throw(env, \"expected a boolean\");\n}\n\n");
    out.append("static inline int vn_f64(napi_env env, napi_value v, double *out) {\n    return napi_get_value_double(env, v, out) == napi_ok || vn_throw(env, \"expected a number\");\n}\n\n");
    out.append("// a number (whole) or a BigInt\nstatic inline int vn_i64(napi_env env, napi_value v, int64_t *out) {\n    napi_valuetype t = napi_undefined;\n    napi_typeof(env, v, &t);\n    if (t == napi_bigint) {\n        bool lossless = false;\n        return napi_get_value_bigint_int64(env, v, out, &lossless) == napi_ok || vn_throw(env, \"expected an integer\");\n    }\n    double d;\n    // NaN and infinities fail the range test before anything is cast\n    if (t != napi_number || napi_get_value_double(env, v, &d) != napi_ok || !(d >= -9223372036854775808.0 && d < 9223372036854775808.0) || d != (double)(int64_t)d) {\n        return vn_throw(env, \"expected an integer\");\n    }\n    *out = (int64_t)d;\n    return 1;\n}\n\n");
    out.append("static inline int vn_u64(napi_env env, napi_value v, uint64_t *out) {\n    napi_valuetype t = napi_undefined;\n    napi_typeof(env, v, &t);\n    if (t == napi_bigint) {\n        bool lossless = false;\n        return napi_get_value_bigint_uint64(env, v, out, &lossless) == napi_ok || vn_throw(env, \"expected an integer\");\n    }\n    double d;\n    if (t != napi_number || napi_get_value_double(env, v, &d) != napi_ok || !(d >= 0 && d < 18446744073709551616.0) || d != (double)(uint64_t)d) {\n        return vn_throw(env, \"expected a whole number, 0 or more\");\n    }\n    *out = (uint64_t)d;\n    return 1;\n}\n\n");
    out.append("// a string's UTF-8 bytes in a buffer the caller frees\nstatic inline int vn_utf8(napi_env env, napi_value v, char **buf, size_t *len) {\n    if (napi_get_value_string_utf8(env, v, NULL, 0, len) != napi_ok) {\n        return vn_throw(env, \"expected a string\");\n    }\n    *buf = malloc(*len + 1);\n    if (!*buf) {\n        return vn_throw(env, \"out of memory\");\n    }\n    napi_get_value_string_utf8(env, v, *buf, *len + 1, len);\n    return 1;\n}\n\n");
    if (this.uses_str) {
        out.append("static inline int vn_str(napi_env env, napi_value v, volt_str *out, char **buf) {\n    size_t len = 0;\n    if (!vn_utf8(env, v, buf, &len)) {\n        return 0;\n    }\n    out->ptr = (const uint8_t *)*buf;\n    out->len = len;\n    return 1;\n}\n\n");
    }
    out.append("static inline int vn_cstr(napi_env env, napi_value v, const char **out, char **buf) {\n    size_t len = 0;\n    if (vn_is_nullish(env, v)) {\n        *out = NULL;\n        return 1;\n    }\n    if (!vn_utf8(env, v, buf, &len)) {\n        return 0;\n    }\n    *out = *buf;\n    return 1;\n}\n\n");
    out.append("static inline int vn_array(napi_env env, napi_value v, uint32_t *n) {\n    bool is = false;\n    napi_is_array(env, v, &is);\n    if (!is || napi_get_array_length(env, v, n) != napi_ok) {\n        return vn_throw(env, \"expected an array\");\n    }\n    return 1;\n}\n\n");
    out.append("static inline int vn_function(napi_env env, napi_value v) {\n    napi_valuetype t = napi_undefined;\n    napi_typeof(env, v, &t);\n    return t == napi_function || vn_throw(env, \"expected a function\");\n}\n\n");
    out.append("static inline int vn_external(napi_env env, napi_value v, void **out) {\n    if (vn_is_nullish(env, v)) {\n        *out = NULL;\n        return 1;\n    }\n    return napi_get_value_external(env, v, out) == napi_ok || vn_throw(env, \"expected a pointer from this library\");\n}\n\n");
    out.append("// a class instance's handle (after a check that it is one), or an error once it's closed\nstatic inline int vn_unwrap(napi_env env, napi_value v, const napi_type_tag *tag, void **out, const char *what) {\n    bool is = false;\n    char msg[160];\n    if (napi_check_object_type_tag(env, v, tag, &is) != napi_ok || !is) {\n        snprintf(msg, sizeof msg, \"expected a %s\", what);\n        return vn_throw(env, msg);\n    }\n    if (napi_unwrap(env, v, out) != napi_ok || !*out) {\n        snprintf(msg, sizeof msg, \"this %s is closed\", what);\n        return vn_throw(env, msg);\n    }\n    return 1;\n}\n\n");
    out.append("static inline napi_value vn_num(napi_env env, double d) {\n    napi_value v = NULL;\n    napi_create_double(env, d, &v);\n    return v;\n}\n\nstatic inline napi_value vn_from_bool(napi_env env, bool b) {\n    napi_value v = NULL;\n    napi_get_boolean(env, b, &v);\n    return v;\n}\n\nstatic inline napi_value vn_from_str(napi_env env, const uint8_t *p, size_t n) {\n    napi_value v = NULL;\n    napi_create_string_utf8(env, (const char *)p, n, &v);\n    return v;\n}\n\nstatic inline napi_value vn_from_cstr(napi_env env, const char *s) {\n    napi_value v = NULL;\n    if (s) {\n        napi_create_string_utf8(env, s, NAPI_AUTO_LENGTH, &v);\n    } else {\n        napi_get_null(env, &v);\n    }\n    return v;\n}\n\nstatic inline napi_value vn_from_external(napi_env env, void *p) {\n    napi_value v = NULL;\n    if (p) {\n        napi_create_external(env, p, NULL, NULL, &v);\n    } else {\n        napi_get_null(env, &v);\n    }\n    return v;\n}\n\n");
    // errors: an Error whose code is the error's name
    out.append("static inline const char *vn_error_name(uint32_t code) {\n    switch (code) {\n");
    for (c&) in this.all_codes().items() {
        out.append(fmt2("    case {}u: return \"{}\";\n", num(c.code), S(c.name)).as_str());
    }
    out.append("    }\n    return \"ERROR\";\n}\n\n// throw an Error for a Volt error code: its code and message are the error's name\nstatic inline void vn_throw_code(napi_env env, uint32_t code) {\n    napi_value msg = NULL, name = NULL, err = NULL, num = NULL;\n    napi_create_string_utf8(env, vn_error_name(code), NAPI_AUTO_LENGTH, &name);\n    napi_create_string_utf8(env, vn_error_name(code), NAPI_AUTO_LENGTH, &msg);\n    napi_create_error(env, name, msg, &err);\n    napi_create_uint32(env, code, &num);\n    napi_set_named_property(env, err, \"errno\", num);\n    napi_throw(env, err);\n}\n");
    // structs: to and from plain objects
    for (s&) in this.structs.items() {
        if (!this.node_simple(this.c.t.intern(tyk::STRUCT(*s)))) {
            continue;
        }
        val sn = this.node_sname(*s);
        val cn = this.c_named(this.c.si(*s).name, false);
        out.append(fmt3("\nstatic inline int vn_get_{}(napi_env env, napi_value v, {} *out) {{\n    napi_valuetype t = napi_undefined;\n    napi_typeof(env, v, &t);\n    if (t != napi_object) {{\n        return vn_throw(env, \"expected a {} object\");\n    }}\n", copy sn, copy cn, copy sn).as_str());
        for (f&) in this.c.si(*s).fields.items() {
            out.append(fmt3("    {{\n        napi_value f;\n        napi_get_named_property(env, v, \"{}\", &f);\n        {}\n    }}\n", S(f.name), this.node_get_simple(f.ty, "f", fmt("out->{}", S(f.name)).as_str()), S("")).as_str());
        }
        out.append("    return 1;\nfail:\n    return 0;\n}\n");
        out.append(fmt2("\nstatic inline void vn_set_{}(napi_env env, napi_value v, const {} *in) {{\n", copy sn, copy cn).as_str());
        for (f&) in this.c.si(*s).fields.items() {
            out.append(fmt2("    napi_set_named_property(env, v, \"{}\", {});\n", S(f.name), this.node_put_simple(f.ty, fmt("in->{}", S(f.name)).as_str())).as_str());
        }
        out.append("}\n");
        out.append(fmt3("\nstatic inline napi_value vn_new_{}(napi_env env, const {} *in) {{\n    napi_value v = NULL;\n    napi_create_object(env, &v);\n    vn_set_{}(env, v, in);\n    return v;\n}}\n", copy sn, copy cn, copy sn).as_str());
    }
    // callbacks: the C function a Volt closure parameter calls, which calls the JS function
    out.append("\n// a JS function passed for a callback (only used during the call)\nstruct vn_cb {\n    napi_env env;\n    napi_value fn;\n};\n");
    for (i) in 0..this.closures.len {
        match (*this.c.t.get(*this.closures.at(i))) {
            .FN_VAL(ps&, r) => {
                var params = S("void *user");
                for (k) in 0..ps.len {
                    params.append(fmt2(", {}a{}", spaced(this.c_prim(*ps.at(k), false)), unum(@cast<u64>(k))).as_str());
                }
                out.append(fmt3("\nstatic {}vn_cb{}({}) {{\n    struct vn_cb *c = user;\n    napi_env env = c->env;\n    napi_value global = NULL, ret = NULL;\n", spaced(this.c_prim(r, false)), unum(@cast<u64>(i)), move params).as_str());
                var argn = ps.len;
                if (argn == 0) {
                    argn = 1;
                }
                out.append(fmt("    napi_value argv[{}];\n", unum(@cast<u64>(argn))).as_str());
                if (r != VOID) {
                    out.append(fmt("    {}out;\n    memset(&out, 0, sizeof out);\n", spaced(this.c_prim(r, false))).as_str());
                }
                for (k) in 0..ps.len {
                    if (!this.node_simple(*ps.at(k))) {
                        match (this.shape_of(*ps.at(k)) ?? shape::VOID) {
                            .STR => { out.append(fmt3("    argv[{}] = vn_from_str(env, a{}.ptr, a{}.len);\n", unum(@cast<u64>(k)), unum(@cast<u64>(k)), unum(@cast<u64>(k))).as_str()); },
                            default => { return fail(NO_SPAN, fmt("a callback taking {} can't call JavaScript", this.c.ty_name(*ps.at(k)))); },
                        }
                    } else {
                        out.append(fmt2("    argv[{}] = {};\n", unum(@cast<u64>(k)), this.node_put_simple(*ps.at(k), fmt("a{}", unum(@cast<u64>(k))).as_str())).as_str());
                    }
                }
                out.append(fmt("    napi_get_global(env, &global);\n    if (napi_call_function(env, global, c->fn, {}, argv, &ret) != napi_ok) {\n        goto fail;\n    }\n", unum(@cast<u64>(ps.len))).as_str());
                if (r != VOID) {
                    if (!this.node_simple(r)) {
                        return fail(NO_SPAN, fmt("a callback returning {} can't call JavaScript", this.c.ty_name(r)));
                    }
                    out.append(fmt("    {}\n", this.node_get_simple(r, "ret", "out")).as_str());
                    out.append("    return out;\nfail:\n    return out;\n}\n");
                } else {
                    out.append("fail:\n    return;\n}\n");
                }
            },
            default => {},
        }
    }
    // classes: a JS class per export struct, owning its handle
    for (s&) in this.handles.items() {
        val sn = this.node_sname(*s);
        val cn = this.handle_c(*s, false);
        out.append(fmt4("\n// export struct {}\nstatic napi_ref vn_class_{};\nstatic const napi_type_tag vn_tag_{} = {};\n", S(this.c.si(*s).name), copy sn, copy sn, this.node_tag(*s)).as_str());
        out.append(fmt3("\nstatic void vn_finalize_{}(napi_env env, void *data, void *hint) {{\n    (void)env;\n    (void)hint;\n    {}((void *)data);\n}}\n", copy sn, this.free_name(*s), S("")).as_str());
        out.append(fmt4("\n// an instance owning handle h\nstatic napi_value vn_wrap_{}(napi_env env, {}h) {{\n    napi_value cls = NULL, ext = NULL, obj = NULL;\n    napi_get_reference_value(env, vn_class_{}, &cls);\n    napi_create_external(env, h, NULL, NULL, &ext);\n    napi_new_instance(env, cls, 1, &ext, &obj);\n    return obj;\n}}\n", copy sn, spaced(copy cn), copy sn, S("")).as_str());
        out.append(fmt2("\n// frees the handle now (it's freed when the object is collected otherwise)\nstatic napi_value vn_close_{}(napi_env env, napi_callback_info info) {{\n    napi_value self = NULL, undef = NULL;\n    void *h = NULL;\n    napi_get_cb_info(env, info, NULL, NULL, &self, NULL);\n    if (napi_remove_wrap(env, self, &h) == napi_ok && h) {{\n        {}(h);\n    }}\n", copy sn, this.free_name(*s)).as_str());
        out.append("    napi_get_undefined(env, &undef);\n    return undef;\n}\n");
        // the constructor: a handle from C (an External), or the class's new
        var maker: u32? = null;
        for (e&) in ents.items() {
            if (e.free_of == null && this.member_of(e.f, *s) != null && (this.member_of(e.f, *s) ?? "") == "new" && this.made_by(e.f, *s) && !this.node_is_method(e.f, *s)) {
                maker = e.f;
            }
        }
        val mk = maker;
        if (mk) {
            try this.node_fn(mk, fmt("vn_new_{}", copy sn).as_str(), null, &out);
        }
        out.append(fmt2("\nstatic napi_value vn_ctor_{}(napi_env env, napi_callback_info info) {{\n    size_t argc = 1;\n    napi_value argv[1], self = NULL, made = NULL;\n    napi_valuetype t0 = napi_undefined;\n    void *h = NULL;\n    if (napi_get_cb_info(env, info, &argc, argv, &self, NULL) != napi_ok) {{\n        return NULL;\n    }}\n    if (argc >= 1) {{\n        napi_typeof(env, argv[0], &t0);\n    }}\n    if (t0 == napi_external) {{\n        napi_get_value_external(env, argv[0], &h);\n    }} else {{\n", copy sn, S("")).as_str());
        if (mk) {
            // run new with the same arguments, then take its handle from the instance it made
            out.append(fmt2("        made = vn_new_{}(env, info);\n        if (!made || napi_remove_wrap(env, made, &h) != napi_ok) {{\n            return NULL;\n        }}\n", copy sn, S("")).as_str());
        } else {
            out.append(fmt("        napi_throw_type_error(env, NULL, \"{} is made by the library's functions\");\n        return NULL;\n", copy sn).as_str());
        }
        out.append(fmt3("    }}\n    napi_wrap(env, self, h, vn_finalize_{}, NULL, NULL);\n    napi_type_tag_object(env, self, &vn_tag_{});\n    return self;\n}}\n", copy sn, copy sn, S("")).as_str());
    }
    // the functions
    for (e&) in ents.items() {
        if (e.free_of != null) {
            continue;
        }
        val cls = this.class_of(e.f);
        if (cls) {
            if (!this.node_is_method(e.f, cls) && (this.member_of(e.f, cls) ?? "") == "new") {
                continue;
            }
            if (this.node_is_method(e.f, cls)) {
                try this.node_fn(e.f, fmt("vn_f_{}", S(this.c.fi(e.f).c_name)).as_str(), cls, &out);
            } else {
                try this.node_fn(e.f, fmt("vn_f_{}", S(this.c.fi(e.f).c_name)).as_str(), null, &out);
            }
        } else {
            try this.node_fn(e.f, fmt("vn_f_{}", S(this.c.fi(e.f).c_name)).as_str(), null, &out);
        }
    }
    // the module
    out.append("\nstatic inline void vn_set_num(napi_env env, napi_value obj, const char *name, double v) {\n    napi_set_named_property(env, obj, name, vn_num(env, v));\n}\n\nstatic inline void vn_set_text(napi_env env, napi_value obj, const char *name, const char *v) {\n    napi_value s = NULL;\n    napi_create_string_utf8(env, v, NAPI_AUTO_LENGTH, &s);\n    napi_set_named_property(env, obj, name, s);\n}\n");
    out.append("\nNAPI_MODULE_EXPORT napi_value napi_register_module_v1(napi_env env, napi_value exports) {\n");
    var nfree: usize = 0;
    for (e&) in ents.items() {
        if (e.free_of == null && this.class_of(e.f) == null) {
            nfree += 1;
        }
    }
    if (nfree > 0) {
        out.append("    napi_property_descriptor fns[] = {\n");
        for (e&) in ents.items() {
            if (e.free_of != null || this.class_of(e.f) != null) {
                continue;
            }
            val n = S(this.c.fi(e.f).c_name);
            out.append(fmt2("        {{\"{}\", NULL, vn_f_{}, NULL, NULL, NULL, napi_enumerable, NULL}},\n", copy n, copy n).as_str());
        }
        out.append(fmt("    };\n    napi_define_properties(env, exports, {}, fns);\n", unum(@cast<u64>(nfree))).as_str());
    }
    for (en&) in this.enums.items() {
        val info = this.c.ei(*en);
        out.append("    {\n        napi_value o = NULL;\n        napi_create_object(env, &o);\n");
        for (i) in 0..info.names.len {
            out.append(fmt2("        vn_set_num(env, o, \"{}\", {});\n", S(*info.names.at(i)), num(*info.values.at(i))).as_str());
        }
        out.append(fmt("        napi_set_named_property(env, exports, \"{}\", o);\n    }\n", this.local(info.name)).as_str());
    }
    for (et&) in this.codes.items() {
        match (*this.c.t.get(*et)) {
            .ENUM(e) => {
                val info = this.c.ei(e);
                out.append("    {\n        napi_value o = NULL;\n        napi_create_object(env, &o);\n");
                for (i) in 0..info.names.len {
                    out.append(fmt2("        vn_set_text(env, o, \"{}\", \"{}\");\n", S(*info.names.at(i)), S(*info.names.at(i))).as_str());
                }
                out.append(fmt("        napi_set_named_property(env, exports, \"{}\", o);\n    }\n", this.local(info.name)).as_str());
            },
            default => {},
        }
    }
    for (s&) in this.handles.items() {
        val sn = this.node_sname(*s);
        out.append("    {\n        napi_property_descriptor ps[] = {\n");
        out.append(fmt("            {\"close\", NULL, vn_close_{}, NULL, NULL, NULL, napi_default_method, NULL},\n", copy sn).as_str());
        var nps: usize = 1;
        for (e&) in ents.items() {
            if (e.free_of != null) {
                continue;
            }
            val m = this.member_of(e.f, *s) ?? continue;
            if (!this.node_is_method(e.f, *s) && m == "new") {
                continue;
            }
            var attr = S("napi_default_method");
            if (!this.node_is_method(e.f, *s)) {
                attr = S("napi_static");
            }
            out.append(fmt3("            {{\"{}\", NULL, vn_f_{}, NULL, NULL, NULL, {}, NULL}},\n", S(m), S(this.c.fi(e.f).c_name), move attr).as_str());
            nps += 1;
        }
        out.append(fmt4("        };\n        napi_value cls = NULL;\n        napi_define_class(env, \"{}\", NAPI_AUTO_LENGTH, vn_ctor_{}, NULL, {}, ps, &cls);\n        napi_create_reference(env, cls, 1, &vn_class_{});\n", copy sn, copy sn, unum(@cast<u64>(nps)), copy sn).as_str());
        out.append(fmt("        napi_set_named_property(env, exports, \"{}\", cls);\n    }\n", copy sn).as_str());
    }
    out.append("    return exports;\n}\n");
    return move out;
}

// is f a method of export struct s (it takes s as its first parameter)?
attach fn node_is_method(this: bind&, f: u32, s: u32) -> bool {
    val info = this.c.fi(f);
    return info.params.len > 0 && this.lends(info.params.at(0).ty, s);
}

// the JS loader: finds NAME.node ($VOLT_NAME_NODE, else next to this file) and gives classes
// Symbol.dispose, for `using`
attach fn js_text(this: bind&) -> std::string {
    var out = fmt("// {}: generated by voltc bindings; loads the Node-API addon (voltc bindings --lang node)\n", S(this.pkg));
    out.append(fmt2("// from $VOLT_{}_NODE, else {}.node next to this file.\n\"use strict\";\nconst path = require(\"path\");\n", upper(this.pkg), S(this.pkg)).as_str());
    out.append(fmt2("const addon = require(process.env.VOLT_{}_NODE || path.join(__dirname, \"{}.node\"));\n", upper(this.pkg), S(this.pkg)).as_str());
    for (s&) in this.handles.items() {
        val sn = this.node_sname(*s);
        out.append(fmt2("if (Symbol.dispose) {{\n    addon.{}.prototype[Symbol.dispose] = addon.{}.prototype.close;\n}}\n", copy sn, copy sn).as_str());
    }
    out.append("module.exports = addon;\n");
    return move out;
}

// TypeScript's view of a type, as a parameter (in) or a result
attach fn ts_ty(this: bind&, t: u32, incoming: bool) -> std::string {
    val h = this.lent_handle(t);
    if (h) {
        return this.node_sname(h);
    }
    match (this.shape_of(t) ?? shape::VOID) {
        .VOID => { return S("void"); },
        .BOOL => { return S("boolean"); },
        .INT(k) => {
            if (incoming && (k == int_ty::I64 || k == int_ty::U64 || k == int_ty::ISIZE || k == int_ty::USIZE)) {
                return S("number | bigint");
            }
            return S("number");
        },
        .FLOAT(b) => { return S("number"); },
        .CSTR => { return S("string | null"); },
        .STR => { return S("string"); },
        .TEXT(x) => { return S("string"); },
        .ENUM(e) => { return this.local(this.c.ei(e).name); },
        .CODE => { return S("number"); },
        .STRUCT(s) => { return this.node_sname(s); },
        .PTR(x) => {
            if (x != VOID && this.node_simple(x)) {
                return this.ts_ty(x, incoming);
            }
            return S("unknown");
        },
        .SLICE(x) => {
            var e = this.ts_ty(x, incoming);
            if (ends_with(e.as_str(), "bigint")) {
                e = fmt("({})", move e);
            }
            e.append("[]");
            return move e;
        },
        .OPT(x) => {
            var v = this.ts_ty(x, incoming);
            v.append(" | null");
            if (incoming) {
                v.append(" | undefined");
            }
            return move v;
        },
        .HANDLE(s) => { return this.node_sname(s); },
        .RESULT(e, x) => { return this.ts_ty(x, incoming); },
        .CLOSURE(i) => {
            match (*this.c.t.get(t)) {
                .FN_VAL(ps&, r) => {
                    var s = S("(");
                    for (k) in 0..ps.len {
                        if (k > 0) {
                            s.append(", ");
                        }
                        s.append(fmt2("a{}: {}", unum(@cast<u64>(k)), this.ts_ty(*ps.at(k), false)).as_str());
                    }
                    s.append(") => ");
                    s.append(this.ts_ty(r, true).as_str());
                    return move s;
                },
                default => { return S("Function"); },
            }
        },
        default => { return S("unknown"); },
    }
}

attach fn ts_params(this: bind&, f: u32, first: usize) -> std::string {
    val info = this.c.fi(f);
    var ps: std::string = {};
    for (k) in first..info.params.len {
        if (ps.len() > 0) {
            ps.append(", ");
        }
        var opt = "";
        match (this.shape_of(info.params.at(k).ty) ?? shape::VOID) {
            .OPT(x) => { opt = "?"; },
            default => {},
        }
        ps.append(fmt3("{}{}: {}", S(info.params.at(k).name), S(opt), this.ts_ty(info.params.at(k).ty, true)).as_str());
    }
    return move ps;
}

// the doc comment above an export fn, as a /** */ line (or nothing)
attach fn ts_doc(this: bind&, f: u32, indent_by: str) -> std::string {
    val sp = this.c.dl(this.c.fi(f).decl).item.span;
    val d = doc_above(this.c.files.at(sp.file).text, @cast<usize>(sp.lo));
    if (d.len() == 0) {
        return {};
    }
    return fmt3("{}/** {} */\n{}", S(indent_by), move d, S(""));
}

attach fn ts_text(this: bind&) -> std::string {
    val ents = this.entries();
    var out = fmt("// {}: generated by voltc bindings; TypeScript types for the Node-API addon\n", S(this.pkg));
    out.append("// (voltc bindings --lang node) and its loader (--lang js). An error a Volt function returns is\n// thrown as a VoltError: its code is the error's name.\n\n");
    out.append("export interface VoltError extends Error {\n    code: string;\n    errno: number;\n}\n");
    for (s&) in this.structs.items() {
        if (!this.node_simple(this.c.t.intern(tyk::STRUCT(*s)))) {
            continue;
        }
        out.append(fmt("\nexport interface {} {{\n", this.node_sname(*s)).as_str());
        for (f&) in this.c.si(*s).fields.items() {
            out.append(fmt2("    {}: {};\n", S(f.name), this.ts_ty(f.ty, false)).as_str());
        }
        out.append("}\n");
    }
    for (e&) in this.enums.items() {
        val info = this.c.ei(*e);
        val n = this.local(info.name);
        out.append(fmt("\nexport declare const {}: {{\n", copy n).as_str());
        var union: std::string = {};
        for (i) in 0..info.names.len {
            out.append(fmt2("    readonly {}: {};\n", S(*info.names.at(i)), num(*info.values.at(i))).as_str());
            if (i > 0) {
                union.append(" | ");
            }
            union.append(num(*info.values.at(i)).as_str());
        }
        out.append(fmt2("}};\nexport type {} = {};\n", copy n, move union).as_str());
    }
    for (et&) in this.codes.items() {
        match (*this.c.t.get(*et)) {
            .ENUM(e) => {
                val info = this.c.ei(e);
                val n = this.local(info.name);
                out.append(fmt2("\n/** the names error set {} throws, as VoltError.code */\nexport declare const {}: {{\n", S(info.name), copy n).as_str());
                for (i) in 0..info.names.len {
                    out.append(fmt2("    readonly {}: \"{}\";\n", S(*info.names.at(i)), S(*info.names.at(i))).as_str());
                }
                out.append("};\n");
            },
            default => {},
        }
    }
    for (s&) in this.handles.items() {
        val sn = this.node_sname(*s);
        out.append(fmt2("\n/** export struct {}: close() frees it now (or `using`); otherwise it's freed when collected */\nexport declare class {} {{\n", S(this.c.si(*s).name), copy sn).as_str());
        for (e&) in ents.items() {
            if (e.free_of != null) {
                continue;
            }
            val m = this.member_of(e.f, *s) ?? continue;
            val info = this.c.fi(e.f);
            out.append(this.ts_doc(e.f, "    ").as_str());
            if (this.node_is_method(e.f, *s)) {
                out.append(fmt3("    {}({}): {};\n", S(m), this.ts_params(e.f, 1), this.ts_ty(info.ret, false)).as_str());
            } else if (m == "new") {
                out.append(fmt("    constructor({});\n", this.ts_params(e.f, 0)).as_str());
            } else {
                out.append(fmt3("    static {}({}): {};\n", S(m), this.ts_params(e.f, 0), this.ts_ty(info.ret, false)).as_str());
            }
        }
        out.append("    close(): void;\n    [Symbol.dispose](): void;\n}\n");
    }
    out.append("\n");
    for (e&) in ents.items() {
        if (e.free_of != null || this.class_of(e.f) != null) {
            continue;
        }
        val info = this.c.fi(e.f);
        out.append(this.ts_doc(e.f, "").as_str());
        out.append(fmt3("export declare function {}({}): {};\n", S(info.c_name), this.ts_params(e.f, 0), this.ts_ty(info.ret, false)).as_str());
    }
    return move out;
}

// ---------- the command ----------

// the bindings of package pkg in lang (c, cpp, rust, zig, python; node, js and ts: a Node-API addon,
// its loader and its types; json: the model itself)
attach fn bindings(this: checker&, pkg: str, lang: str) -> compile_error!std::string {
    var b: bind = { c: this, pkg: pkg };
    val fns = b.exports();
    if (fns.len == 0) {
        return fail(NO_SPAN, fmt("package {} has no export fns to make bindings for", S(pkg)));
    }
    try b.check_all();
    if (lang == "c") {
        return b.c_text();
    }
    if (lang == "cpp") {
        return b.cpp_text();
    }
    if (lang == "rust") {
        return b.rust_text();
    }
    if (lang == "zig") {
        return b.zig_text();
    }
    if (lang == "python") {
        return b.py_text();
    }
    if (lang == "json") {
        return b.json_text();
    }
    if (lang == "node") {
        return b.node_text();
    }
    if (lang == "js") {
        return b.js_text();
    }
    if (lang == "ts") {
        return b.ts_text();
    }
    return fail(NO_SPAN, fmt("--lang takes c, cpp, rust, zig, python, node, js, ts or json, not '{}'", S(lang)));
}
