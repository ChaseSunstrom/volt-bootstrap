// Bindings for other languages: `voltc bindings NAME --lang L` describes package NAME's export fns
// and the types they use, for programs that call a library built with `voltc lib NAME --shared`
// (or `--static`); L is c, cpp, rust, zig, python, pyi, csharp, java, go, lua, dart, swift, kotlin,
// ruby, node, js, ts or json. Every type crosses in a C form:
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
    CLOSURE: u32,      // a fn(A) -> R (its index in bind.closures)
    TRAIT: u32,        // a trait as a type (its index in bind.traits): a table of its fns and the object
}

// what can sit inside another type's C form (a field, an element, a fn pointer's parameter): not the
// shapes that only work at the edge of an export fn
fn plain(s: shape) -> bool {
    match (s) {
        .TEXT(t) => { return false; },
        .HANDLE(h) => { return false; },
        .CLOSURE(c) => { return false; },
        .OPT(t) => { return false; },
        .TRAIT(t) => { return false; },
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
    traits: std::vec<u32> = {};   // trait union types
    closures_out: std::vec<u32> = {}; // the closures (indexes in closures) export fns give out
    // the struct, optional and E!T types C holds by value, each after what it holds (the order C
    // declares them in)
    layout: std::vec<u32> = {};
    // the shapes only C, C++, Rust and Zig take (traits, closures given out or taking text and handles, owned
    // values as parameters): false for the other languages' generators
    wide: bool = true;
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

// is struct s held by a handle in other languages (they never look inside)? An export struct is,
// and so is one C can't hold by value: one that owns something (has a delete, or a field that does)
// or has a field without a C form that sits inside a struct (text, an optional, a closure)
attach fn is_handle(this: bind&, s: u32) -> bool {
    match (this.c.item_of(this.c.si(s).decl).kind) {
        .STRUCT(sd&) => {
            if (sd.is_export) {
                return true;
            }
        },
        default => { return false; },
    }
    if (has_u32(&this.handles, s)) {
        return true;
    }
    if (has_u32(&this.structs, s) || has_u32(&this.visiting, s)) {
        return false;
    }
    val st = this.c.t.intern(tyk::STRUCT(s));
    if (this.c.needs_drop(st) catch false) {
        return true;
    }
    // its fields, looked at without collecting what they need
    var probe: bind = { c: this.c, pkg: this.pkg, wide: this.wide, visiting: copy this.visiting };
    put(&probe.visiting, s);
    for (f&) in this.c.si(s).fields.items() {
        if (probe.inner(f.ty) == null) {
            return true;
        }
    }
    return false;
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
        .REF(x) => {
            // a trait object lent to the fn
            match (*this.c.t.get(x)) {
                .TRAIT_UNION(u) => { return this.shape_of(x); },
                default => {},
            }
            return this.pointer(x);
        },
        .OPT(x) => {
            // a null pointer is "none" for the types that are pointers in C
            match (*this.c.t.get(x)) {
                .REF(y) => { return this.pointer(y); },
                .PTR(y) => { return this.pointer(y); },
                .CSTR => { return shape::CSTR; },
                .FN_PTR(ps, r, va) => { return this.shape_of(x); },
                default => {},
            }
            if (this.c.niche(x)) {
                return this.no_form(t);
            }
            this.inner(x) ?? return null;
            add_u32(&this.opts, x);
            add_u32(&this.layout, t);
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
            if (this.text_method(s) != null && !this.is_export_struct(s)) {
                // C and C++ take text as a str (a parameter, a callback's argument)
                if (this.wide) {
                    this.uses_str = true;
                }
                add_u32(&this.texts, t);
                return shape::TEXT(t);
            }
            if (this.is_handle(s)) {
                add_u32(&this.handles, s);
                return shape::HANDLE(s);
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
            add_u32(&this.layout, t);
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
            add_u32(&this.layout, t);
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
                this.sig_part(*p) ?? return null;
            }
            this.sig_part(r) ?? return null;
            for (i) in 0..this.closures.len {
                if (*this.closures.at(i) == t) {
                    return shape::CLOSURE(@cast<u32>(i));
                }
            }
            put(&this.closures, t);
            return shape::CLOSURE(@cast<u32>(this.closures.len - 1));
        },
        .TRAIT_UNION(u) => {
            for (i) in 0..this.traits.len {
                if (*this.traits.at(i) == t) {
                    return shape::TRAIT(@cast<u32>(i));
                }
            }
            if (!this.wide) {
                return this.no_form(t);
            }
            val fns = this.trait_fns(u) ?? return this.no_form(t);
            // a pointer back to the trait from its own fns is fine: it's declared by then
            put(&this.traits, t);
            for (f&) in fns.items() {
                for (p&) in f.params.items() {
                    this.sig_part(*p) ?? return null;
                }
                this.sig_part(f.ret) ?? return null;
            }
            return shape::TRAIT(@cast<u32>(this.traits.len - 1));
        },
        default => { return this.no_form(t); },
    }
}

// is struct s declared export struct?
attach fn is_export_struct(this: bind&, s: u32) -> bool {
    match (this.c.item_of(this.c.si(s).decl).kind) {
        .STRUCT(sd&) => { return sd.is_export; },
        default => { return false; },
    }
}

// a type in a closure's or a trait fn's signature: what sits inside other types, and (in C and C++)
// text, str and handles, owned or lent, which the callers convert
attach fn sig_part(this: bind&, t: u32) -> shape? {
    if (!this.wide) {
        return this.inner(t);
    }
    val s = this.shape_of(t) ?? return null;
    match (s) {
        .TEXT(x) => { return s; },
        .HANDLE(h) => { return s; },
        .RESULT(e, x) => {
            // E!T of text or a handle: only an export fn's result converts that
            if (this.owned_result(s)) {
                return this.no_form(t);
            }
        },
        default => {},
    }
    if (!plain(s)) {
        return this.no_form(t);
    }
    return s;
}

// one fn of a trait, as other languages implement or call it
struct trait_fn {
    name: str;
    params: std::vec<u32>; // the types after this
    ret: u32;
}

// the fns of trait union u (none when its trait or one of its fns is generic: C has no generics);
// static fns can't be called on a trait's value, so they're left out
attach fn trait_fns(this: bind&, u: u32) -> std::vec<trait_fn>? {
    val td = this.c.ui(u).trait_decl;
    val it = this.c.item_of(td);
    if (it.generics.len > 0) {
        return null;
    }
    val e = this.c.new_env({ ns: this.c.dl(td).ns });
    var out: std::vec<trait_fn> = {};
    match (it.kind) {
        .TRAIT(n, fs&) => {
            for (fi&) in fs.items() {
                match (fi.kind) {
                    .FN(fd&) => {
                        if (fi.generics.len > 0) {
                            return null;
                        }
                        var ps: std::vec<u32> = {};
                        var takes_this = false;
                        for (p&) in fd.params.items() {
                            if (p.name == "this") {
                                takes_this = !p.is_static;
                                continue;
                            }
                            if (p.ty == null) {
                                return null;
                            }
                            put(&ps, this.c.resolve_type(&p.ty.value, e) catch return null);
                        }
                        var r = VOID;
                        if (fd.ret) {
                            r = this.c.resolve_type(&fd.ret, e) catch return null;
                        }
                        if (takes_this) {
                            put(&out, { name: fd.name, params: move ps, ret: r });
                        }
                    },
                    default => {},
                }
            }
        },
        default => { return null; },
    }
    return out;
}

// does t lend what it points at (T&), rather than give it (T)?
attach fn is_ref(this: bind&, t: u32) -> bool {
    match (*this.c.t.get(t)) {
        .REF(x) => { return true; },
        default => { return false; },
    }
}

// the trait union a trait shape stands for (T&'s T)
attach fn trait_of(this: bind&, t: u32) -> u32 {
    match (*this.c.t.get(t)) {
        .REF(x) => { return x; },
        default => { return t; },
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
            .TRAIT(y) => { return this.no_form(x); },
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
    return out;
}

// X_free's name for export struct s
attach fn free_name(this: bind&, s: u32) -> std::string {
    var n = this.local(this.c.si(s).name);
    n.append("_free");
    return n;
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
    return out;
}

// "WHAT is T, which has no C form" (naming the part of T that doesn't cross, when that's inside it)
attach fn no_c_form(this: bind&, at: span, what: std::string, t: u32) -> compile_error {
    var msg = fmt2("{} is {}, which has no C form", move what, this.c.ty_name(t));
    if (this.bad != t) {
        msg.append(fmt(" (because of the {} in it)", this.c.ty_name(this.bad)).as_str());
    }
    return with_help(fail(at, move msg), S("bindings take numbers, bool, pointers and references, cstr, str, slices, optionals, structs of those, plain enums, error sets, E!T, extern \"C\" fns, closures as parameters, and structs held by handles and owned text (@export_text) as results; C, C++, Rust and Zig take traits, owned values as parameters and closures given back too"));
}

// is a shape owned when it comes out of Volt (text, a handle by value, a closure, a trait's object),
// directly or as E!T's value?
attach fn owned_result(this: bind&, s: shape) -> bool {
    match (s) {
        .TEXT(t) => { return true; },
        .HANDLE(h) => { return true; },
        .CLOSURE(c) => { return true; },
        .TRAIT(x) => { return true; },
        .RESULT(e, x) => {
            val v = this.shape_of(x) ?? return false;
            match (v) {
                .RESULT(e2, x2) => { return false; },
                default => { return this.owned_result(v); },
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
            var owned = false;
            match (s) {
                .TEXT(t) => { owned = true; },
                .HANDLE(h) => { owned = true; },
                .RESULT(e, x) => {
                    if (this.owned_result(s)) {
                        return fail(at, fmt3("export fn {}: its parameter {} is {}, which only comes out of export fns", S(f.name), S(p.name), this.c.ty_name(p.ty)));
                    }
                },
                default => {},
            }
            if (owned && !this.wide) {
                return with_help(fail(at, fmt3("export fn {}: its parameter {} is {}, which this language's bindings only take as a result", S(f.name), S(p.name), this.c.ty_name(p.ty))), S("take an export struct as X& (or X*) and text as str; C, C++, Rust and Zig bindings take owned values too"));
            }
        }
        val r = this.shape_of(f.ret) ?? return this.no_c_form(at, fmt("export fn {}: its return type", S(f.name)), f.ret);
        var given = r;
        match (r) {
            .RESULT(e, x) => { given = this.shape_of(x) ?? shape::VOID; },
            default => {},
        }
        match (given) {
            .CLOSURE(c) => { add_u32(&this.closures_out, c); },
            default => {},
        }
        match (r) {
            .CLOSURE(c) => {
                if (!this.wide) {
                    return fail(at, fmt2("export fn {}: it returns {}, and this language's bindings only take closures as parameters (C, C++, Rust and Zig take them back too)", S(f.name), this.c.ty_name(f.ret)));
                }
            },
            default => {},
        }
    }
    // the names voltc lib adds: X_free for each handle, and the shims' namespace
    for (i&) in this.exports().items() {
        val f = this.c.fi(*i);
        for (h&) in this.handles.items() {
            if (this.free_name(*h).as_str() == f.c_name) {
                return with_help(fail(this.c.dl(f.decl).item.span, fmt3("export fn {}: voltc lib makes {} itself, to free struct {}", S(f.c_name), S(f.c_name), S(this.c.si(*h).name))), S("rename this fn; the generated one runs the struct's delete and frees its memory"));
            }
        }
    }
    val pkg_ns = this.c.ns(0).children.get(this.pkg);
    if (pkg_ns != null && this.c.ns(*pkg_ns).children.get("__export") != null) {
        return fail(NO_SPAN, fmt("package {} declares namespace __export, which voltc lib needs for its shims", S(this.pkg)));
    }
    return;
}

// does export fn f need a shim (its C form differs from how Volt passes it, or it's a generic's
// instance, which the shim names)?
attach fn needs_shim(this: bind&, f: u32) -> bool {
    val info = this.c.fi(f);
    if (this.c.fn_generics(info.decl).len > 0) {
        return true;
    }
    for (p&) in info.params.items() {
        match (this.shape_of(p.ty) ?? shape::VOID) {
            .CLOSURE(c) => { return true; },
            .TRAIT(x) => { return true; },
            .TEXT(x) => { return true; },
            .HANDLE(h) => { return true; },
            default => {},
        }
    }
    return this.owned_result(this.shape_of(info.ret) ?? shape::VOID);
}

// ---------- shims ----------

// What voltc lib compiles in front of a package's export fns whose C form differs from Volt's (owned
// text, handles by value, closures, traits): Volt source for export fns of the same names in their C
// forms, in namespace PKG::__export, which call the package's own fns (no longer exported); and an
// X_free per handle. It uses only the language and the runtime's allocator, never std.
struct shim_plan {
    text: std::string = {};
    unexport: std::vec<std::string> = {}; // the package's export fns a shim stands in for (full::name@offset)
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

// K, t's index in v, as text
fn index_of(v: std::vec<u32>&, t: u32) -> std::string {
    for (k) in 0..v.len {
        if (*v.at(k) == t) {
            return unum(@cast<u64>(k));
        }
    }
    return S("0");
}

// an export fn's full Volt name (mathlib::geo::area), which the shims call it by
attach fn full_name(this: bind&, f: u32) -> std::string {
    val info = this.c.fi(f);
    var n = this.c.ns_path(this.c.dl(info.decl).ns, "::");
    if (n.len() > 0) {
        n.append("::");
    }
    n.append(info.name);
    return n;
}

// the expression that turns v (a Volt value of type t, given away) into its C form: text_K(v),
// own_K(v), box_K(v) (a closure) or give_K(v) (a trait's value)
attach fn wrap_owned(this: bind&, t: u32, v: std::string) -> std::string {
    match (this.shape_of(t) ?? shape::VOID) {
        .TEXT(x) => { return fmt2("text_{}({})", index_of(&this.texts, t), move v); },
        .HANDLE(s) => { return fmt2("own_{}({})", index_of(&this.handles, s), move v); },
        .CLOSURE(i) => { return fmt2("box_{}({})", unum(@cast<u64>(i)), move v); },
        .TRAIT(i) => { return fmt2("give_{}({})", unum(@cast<u64>(i)), move v); },
        default => { return v; },
    }
}

// the expression that turns v (type t's C form, coming into Volt) into a Volt value: a parameter
// (text comes as str) or a callback's result (text comes as text, and is freed)
attach fn unwrap_in(this: bind&, t: u32, v: std::string, result: bool) -> std::string {
    match (this.shape_of(t) ?? shape::VOID) {
        .TEXT(x) => {
            if (result) {
                return fmt2("untext_{}({})", index_of(&this.texts, t), move v);
            }
            return fmt2("{}::from({})", this.src(t), move v);
        },
        .HANDLE(s) => { return fmt2("take_{}({})", index_of(&this.handles, s), move v); },
        default => { return v; },
    }
}

// the expression that hands v (a Volt value of type t, a callback's argument) to C: text is lent as
// its str, a handle by value is given away
attach fn lend_out(this: bind&, t: u32, v: std::string) -> std::string {
    match (this.shape_of(t) ?? shape::VOID) {
        .TEXT(x) => {
            match (*this.c.t.get(t)) {
                .STRUCT(s) => { return fmt2("{}.{}()", move v, S(this.text_method(s) ?? "as_str")); },
                default => {},
            }
        },
        .HANDLE(s) => { return fmt2("own_{}(move {})", index_of(&this.handles, s), move v); },
        default => {},
    }
    return v;
}

// type t's C form as Volt source: as a parameter (text as str) or a result (text as text)
attach fn c_src(this: bind&, t: u32, result: bool) -> std::string {
    match (this.shape_of(t) ?? shape::VOID) {
        .TEXT(x) => {
            if (result) {
                return S("text");
            }
            return S("str");
        },
        .HANDLE(s) => { return fmt("({}*)", this.src(t)); },
        .CLOSURE(i) => { return fmt("closure_{}", unum(@cast<u64>(i))); },
        .TRAIT(i) => { return fmt("object_{}", unum(@cast<u64>(i))); },
        .RESULT(e, x) => {
            if (this.owned_result(shape::RESULT(e, x))) {
                return fmt2("{}!{}", this.err_src(e), this.c_src(x, true));
            }
        },
        default => {},
    }
    return this.src(t);
}

// an extern "C" fn type as Volt source: the data first, then params' C forms, then r's
attach fn c_fn_src(this: bind&, ps: std::vec<u32>&, r: u32) -> std::string {
    var s = S("extern \"C\" fn(void*");
    for (p&) in ps.items() {
        s.append(", ");
        s.append(this.c_src(*p, false).as_str());
    }
    s.append(") -> ");
    s.append(this.c_src(r, true).as_str());
    return s;
}

// a call of C function f (a value), with data, lending a Volt fn's params a0.. to it, the result
// taken back into Volt: the body of a Volt fn that calls into C
attach fn call_out(this: bind&, f: str, data: str, ps: std::vec<u32>&, r: u32) -> std::string {
    var args = S(data);
    for (k) in 0..ps.len {
        args.append(", ");
        args.append(this.lend_out(*ps.at(k), fmt("a{}", unum(@cast<u64>(k)))).as_str());
    }
    val call = fmt2("{}({})", S(f), move args);
    if (r == VOID) {
        return fmt("{};", move call);
    }
    return fmt("return {};", this.unwrap_in(r, move call, true));
}

// a Volt call of what (the callee, with "(" to come) taking C params a0.., its result given to C:
// the body of an extern "C" fn that C calls into Volt with
attach fn call_in(this: bind&, what: std::string, ps: std::vec<u32>&, r: u32) -> std::string {
    var call = move what;
    for (k) in 0..ps.len {
        if (k > 0) {
            call.append(", ");
        }
        call.append(this.unwrap_in(*ps.at(k), fmt("a{}", unum(@cast<u64>(k))), false).as_str());
    }
    call.push(')');
    if (r == VOID) {
        return fmt("{};", move call);
    }
    return fmt("return {};", this.wrap_owned(r, move call));
}

// "a0: T0, a1: T1": a Volt fn's params, or their C forms
attach fn param_list(this: bind&, ps: std::vec<u32>&, c: bool) -> std::string {
    var out: std::string = {};
    for (k) in 0..ps.len {
        if (k > 0) {
            out.append(", ");
        }
        var ty = this.src(*ps.at(k));
        if (c) {
            ty = this.c_src(*ps.at(k), false);
        }
        out.append(fmt2("a{}: {}", unum(@cast<u64>(k)), move ty).as_str());
    }
    return out;
}

// a closure type's params and result
attach fn fn_parts(this: bind&, t: u32, ps: std::vec<u32>&) -> u32 {
    match (*this.c.t.get(t)) {
        .FN_VAL(xs&, r) => {
            for (x&) in xs.items() {
                put(ps, *x);
            }
            return r;
        },
        default => { return VOID; },
    }
}

attach fn shim_fn(this: bind&, f: u32, out: std::string&) -> void {
    val info = this.c.fi(f);
    val is_attach = this.c.fn_decl_of(info.decl)->is_attach;
    var params: std::string = {};
    var pre: std::string = {};
    var args: std::vec<std::string> = {};
    for (p&) in info.params.items() {
        if (params.len() > 0) {
            params.append(", ");
        }
        var pn = S(p.name);
        if (p.name == "this") {
            pn = S("this_");
        }
        match (this.shape_of(p.ty) ?? shape::VOID) {
            .CLOSURE(c) => {
                // the caller's C function, which takes the caller's data first, and that data
                var ps: std::vec<u32> = {};
                val r = this.fn_parts(p.ty, &ps);
                params.append(fmt3("{}: {}, {}_user: void*", copy pn, this.c_fn_src(&ps, r), copy pn).as_str());
                var user = copy pn;
                user.append("_user");
                var lam = fmt4("|{}, {}| ({}) -> {} {{ ", copy pn, copy user, this.param_list(&ps, false), this.src(r));
                lam.append(this.call_out(pn.as_str(), user.as_str(), &ps, r).as_str());
                lam.append(" }");
                put(&args, move lam);
            },
            .TRAIT(i) => {
                // the caller's object joins the trait (foreign_K attaches it): lent (never freed)
                // unless the fn takes the trait by value
                val ik = unum(@cast<u64>(i));
                params.append(fmt2("{}: object_{}", copy pn, copy ik).as_str());
                var drop = fmt("{}.drop", copy pn);
                if (this.is_ref(p.ty)) {
                    drop = S("null");
                }
                pre.append(fmt4("        val {}_f: foreign_{} = {{ vt: {}.vt, self_: {}.self_, drop: ", copy pn, copy ik, copy pn, copy pn).as_str());
                pre.append(fmt4("{} }};\n        var {}_v: {} = move {}_f;\n", move drop, copy pn, this.src(this.trait_of(p.ty)), copy pn).as_str());
                if (this.is_ref(p.ty)) {
                    put(&args, fmt("&{}_v", copy pn));
                } else {
                    put(&args, fmt("move {}_v", copy pn));
                }
            },
            default => {
                params.append(fmt2("{}: {}", copy pn, this.c_src(p.ty, false)).as_str());
                put(&args, this.unwrap_in(p.ty, copy pn, false));
            },
        }
    }
    var call: std::string = {};
    var first: usize = 0;
    if (is_attach && args.len > 0) {
        // a method: called on its first argument
        call = fmt2("{}.{}(", copy *args.at(0), S(this.c.fn_decl_of(info.decl)->name));
        first = 1;
    } else {
        call = fmt("{}(", this.full_name(f));
    }
    for (k) in first..args.len {
        if (k > first) {
            call.append(", ");
        }
        call.append(args.at(k).as_str());
    }
    call.push(')');
    var ret = this.c_src(info.ret, true);
    var body: std::string = {};
    match (this.shape_of(info.ret) ?? shape::VOID) {
        .RESULT(e, x) => {
            if (this.owned_result(shape::RESULT(e, x))) {
                body = fmt("return {};", this.wrap_owned(x, fmt("try {}", move call)));
            } else {
                body = fmt("return {};", move call);
            }
        },
        .VOID => { body = fmt("{};", move call); },
        default => { body = fmt("return {};", this.wrap_owned(info.ret, move call)); },
    }
    out.append(fmt4("\n    export fn {}({}) -> {} {{\n{}", S(info.c_name), move params, move ret, move pre).as_str());
    out.append(fmt("        {}\n    }\n", move body).as_str());
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
            // the decl's full name and where it is (an instance's decl goes once)
            val d = this.fi(*i).decl;
            var key = this.ns_path(this.dl(d).ns, "::");
            key.append("::");
            key.append(this.fn_decl_of(d)->name);
            key.push('@');
            key.append(this.files.at(this.dl(d).item.span.file).name);
            key.push(':');
            key.append_uint(@cast<u64>(this.dl(d).item.span.lo));
            var have = false;
            for (k&) in plan.unexport.items() {
                if (k.as_str() == key.as_str()) {
                    have = true;
                }
            }
            if (!have) {
                put(&plan.unexport, move key);
            }
        }
    }
    val ents = b.entries();
    if (fns.len() == 0 && b.handles.len == 0 && b.texts.len == 0 && b.closures.len == 0 && b.traits.len == 0) {
        return plan;
    }
    // what the shims give out: a closure's box, a trait's objects (given only when returned)
    var extra: std::string = {};
    for (k) in 0..b.closures.len {
        if (contains(fns.as_str(), fmt("box_{}(", unum(@cast<u64>(k))).as_str())) {
            b.closure_shim(@cast<u32>(k), &extra);
        }
    }
    for (k) in 0..b.traits.len {
        b.trait_shim(@cast<u32>(k), contains(fns.as_str(), fmt("give_{}(", unum(@cast<u64>(k))).as_str()), &extra);
    }
    var used = copy fns;
    used.append(extra.as_str());
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
        if (contains(used.as_str(), fmt("untext_{}(", copy kk).as_str())) {
            // text a callback gave back: copied, then freed
            out.append(fmt3("\n    fn untext_{}(t: text) -> {} {{\n        val v = {}::from(@cast<str>(@slice(t.ptr, t.len)));\n        val d = t.drop;\n        d(t.owner);\n        return v;\n    }}\n", copy kk, copy ts, copy ts).as_str());
        }
    }
    if (b.texts.len > 0) {
        // owned text freed by a real symbol, for languages that can't call a C function pointer
        out.append(fmt("\n    // frees owned text an export fn gave out\n    export fn {}_text_free(t: text) -> void {{\n        val d = t.drop;\n        d(t.owner);\n    }}\n", S(pkg)).as_str());
    }
    for (k) in 0..b.handles.len {
        val s = *b.handles.at(k);
        val xs = S(this.si(s).name);
        val kk = unum(@cast<u64>(k));
        out.append(fmt4("\n    fn own_{}(v: {}) -> {}* {{\n        val p = @cast<{}*>(rt_malloc(@sizeof(", copy kk, copy xs, copy xs, copy xs).as_str());
        out.append(fmt("{})) ?? @panic(\"out of memory\"));\n        @write(p, move v);\n        return p;\n    }\n", copy xs).as_str());
        // a handle given to Volt: it owns the value from here
        out.append(fmt3("\n    fn take_{}(p: {}*) -> {} {{\n        val v = @read(p);\n        rt_free(@cast<void*>(p));\n        return v;\n    }}\n", copy kk, copy xs, copy xs).as_str());
    }
    out.append(extra.as_str());
    for (e&) in ents.items() {
        val s = e.free_of ?? continue;
        out.append(fmt2("\n    // frees what an export fn gave out (null does nothing)\n    export fn {}(it: {}*) -> void {{\n        if (it == null) {{\n            return;\n        }}\n        val v = @read(it);\n        rt_free(@cast<void*>(it));\n    }}\n", copy e.name, S(this.si(s).name)).as_str());
    }
    out.append(fns.as_str());
    out.append("}\n");
    plan.text = move out;
    return plan;
}

// closure type K given to C (an export fn returns it): boxed, with the C function that calls it and
// the one that frees the box
attach fn closure_shim(this: bind&, k: u32, out: std::string&) -> void {
    val t = *this.closures.at(k);
    var ps: std::vec<u32> = {};
    val r = this.fn_parts(t, &ps);
    val kk = unum(@cast<u64>(k));
    val fs = fmt("({})", this.src(t));
    out.append(fmt3("\n    // {}, given to C: call(self, ...) calls it, drop(self) frees it\n    struct closure_{} {{\n        call: {};\n        self_: void*;\n        drop: extern \"C\" fn(void*) -> void;\n    }}\n", this.src(t), copy kk, this.c_fn_src(&ps, r)).as_str());
    var params = S("p: void*");
    if (ps.len > 0) {
        params.append(", ");
        params.append(this.param_list(&ps, true).as_str());
    }
    out.append(fmt4("\n    extern \"C\" fn call_{}({}) -> {} {{\n        val f = @cast<{}*>(p);\n", copy kk, move params, this.c_src(r, true), copy fs).as_str());
    out.append(fmt("        {}\n    }\n", this.call_in(S("(*f)("), &ps, r)).as_str());
    out.append(fmt2("\n    extern \"C\" fn drop_closure_{}(p: void*) -> void {{\n        val f = @read(@cast<{}*>(p));\n        rt_free(p);\n    }}\n", copy kk, copy fs).as_str());
    out.append(fmt4("\n    fn box_{}(f: {}) -> closure_{} {{\n        val p = @cast<{}*>(rt_malloc(@sizeof(", copy kk, copy fs, copy kk, copy fs).as_str());
    out.append(fmt3("{})) ?? @panic(\"out of memory\"));\n        @write(p, f);\n        return {{ call: call_{}, self_: @cast<void*>(p), drop: drop_closure_{} }};\n    }}\n", copy fs, copy kk, copy kk).as_str());
}

// trait type K: its table of C functions, the object C passes (a table, the object, and what frees
// it, null when lent), which joins the trait; and a Volt value of the trait given to C, boxed with a
// table of C functions that call it
attach fn trait_shim(this: bind&, k: u32, gives: bool, out: std::string&) -> void {
    val t = *this.traits.at(k);
    val ts = this.src(t);
    val kk = unum(@cast<u64>(k));
    var fns: std::vec<trait_fn> = {};
    match (*this.c.t.get(t)) {
        .TRAIT_UNION(u) => { fns = this.trait_fns(u) ?? {}; },
        default => {},
    }
    out.append(fmt2("\n    // trait {}'s fns as C functions taking the object first\n    struct vt_{} {{\n", copy ts, copy kk).as_str());
    for (f&) in fns.items() {
        out.append(fmt2("        {}: {};\n", S(f.name), this.c_fn_src(&f.params, f.ret)).as_str());
    }
    out.append("    }\n");
    out.append(fmt2("\n    struct object_{} {{\n        vt: vt_{}*;\n        self_: void*;\n        drop: (extern \"C\" fn(void*) -> void)?;\n    }}\n", copy kk, copy kk).as_str());
    out.append(fmt2("\n    // another language's object, as a {} (drop is null when it's lent)\n    struct foreign_{} {{\n", copy ts, copy kk).as_str());
    out.append(fmt("        vt: vt_{}*;\n        self_: void*;\n        drop: (extern \"C\" fn(void*) -> void)?;\n    }}\n", copy kk).as_str());
    out.append(fmt("\n    attach {} -> foreign_", copy ts).as_str());
    out.append(fmt("{} {{\n", copy kk).as_str());
    for (f&) in fns.items() {
        var ps = this.param_list(&f.params, false);
        if (ps.len() > 0) {
            ps = fmt(", {}", move ps);
        }
        out.append(fmt4("        fn {}(this{}) -> {} {{\n            val f = this.vt->{};\n", S(f.name), move ps, this.src(f.ret), S(f.name)).as_str());
        out.append(fmt("            {}\n        }\n", this.call_out("f", "this.self_", &f.params, f.ret)).as_str());
    }
    out.append("    }\n");
    out.append(fmt("\n    attach fn delete(this: foreign_{}&) -> void {{\n        val d = this.drop ?? return;\n        d(this.self_);\n    }}\n", copy kk).as_str());
    if (!gives) {
        return;
    }
    // a Volt value given to C
    out.append(fmt3("\n    struct boxed_{} {{\n        vt: vt_{};\n        v: {};\n    }}\n", copy kk, copy kk, copy ts).as_str());
    var table: std::string = {};
    for (f&) in fns.items() {
        var params = S("p: void*");
        if (f.params.len > 0) {
            params.append(", ");
            params.append(this.param_list(&f.params, true).as_str());
        }
        out.append(fmt4("\n    extern \"C\" fn trait_{}_{}({}) -> {} {{\n", copy kk, S(f.name), move params, this.c_src(f.ret, true)).as_str());
        out.append(fmt("        {}\n    }\n", this.call_in(fmt2("@cast<boxed_{}*>(p)->v.{}(", copy kk, S(f.name)), &f.params, f.ret)).as_str());
        if (table.len() > 0) {
            table.append(", ");
        }
        table.append(fmt3("{}: trait_{}_{}", S(f.name), copy kk, S(f.name)).as_str());
    }
    out.append(fmt2("\n    extern \"C\" fn drop_boxed_{}(p: void*) -> void {{\n        val b = @read(@cast<boxed_{}*>(p));\n        rt_free(p);\n    }}\n", copy kk, copy kk).as_str());
    out.append(fmt4("\n    fn give_{}(v: {}) -> object_{} {{\n        val p = @cast<boxed_{}*>(rt_malloc(@sizeof(", copy kk, copy ts, copy kk, copy kk).as_str());
    out.append(fmt2("boxed_{})) ?? @panic(\"out of memory\"));\n        @write(p, {{ vt: {{ {} }}, v: move v }});\n", copy kk, move table).as_str());
    out.append(fmt("        return {{ vt: &p->vt, self_: @cast<void*>(p), drop: drop_boxed_{} }};\n    }}\n", copy kk).as_str());
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
    return out;
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
    return out;
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
        .TRAIT_UNION(u) => { return this.local(this.c.ty_name(t).as_str()); },
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
            return n;
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
    return n;
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
            return s;
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
            return n;
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
        .TRAIT(i) => {
            // the object (a table and the object's pointer): pkg_T in C, T_obj in C++ (T is the class)
            if (cpp) {
                return fmt("{}_obj", this.short(this.trait_of(t)));
            }
            return this.c_named(this.short(this.trait_of(t)).as_str(), false);
        },
    }
}

// type t's C form as a parameter: text comes in as a str
attach fn c_in(this: bind&, t: u32, cpp: bool) -> std::string {
    match (this.shape_of(t) ?? shape::VOID) {
        .TEXT(x) => { return this.c_prim(STR, cpp); },
        default => { return this.c_prim(t, cpp); },
    }
}

// type t's C form as a result: a closure comes out boxed
attach fn c_out(this: bind&, t: u32, cpp: bool) -> std::string {
    match (this.shape_of(t) ?? shape::VOID) {
        .CLOSURE(i) => {
            var n = S("closure");
            n.append_uint(@cast<u64>(i));
            return this.c_named(n.as_str(), cpp);
        },
        default => { return this.c_prim(t, cpp); },
    }
}

// the C function type a closure or a trait's fn is: (data first, the params, the result) as a
// declaration of name
attach fn c_fn_decl(this: bind&, ps: std::vec<u32>&, r: u32, name: str, cpp: bool) -> std::string {
    var args = S("void *self");
    for (p&) in ps.items() {
        args.append(", ");
        args.append(this.c_in(*p, cpp).as_str());
    }
    var n = S(name);
    if (cpp) {
        n = cpp_ident(name);
    }
    return fmt3("{}(*{})({})", spaced(this.c_out(r, cpp)), move n, move args);
}

// a C type ready for a name after it: "int " but "char *"
fn spaced(t: std::string) -> std::string {
    var s = move t;
    if (!ends_with(s.as_str(), "*")) {
        s.push(' ');
    }
    return s;
}

// "T name" (with [N] after the name for arrays)
attach fn c_decl(this: bind&, t: u32, name: str, cpp: bool) -> std::string {
    var s = this.c_prim(t, cpp);
    if (!ends_with(s.as_str(), "*")) {
        s.push(' ');
    }
    if (cpp) {
        s.append(cpp_ident(name).as_str());
    } else if (name == "this") {
        s.append("self");
    } else if (cpp_keyword(name)) {
        // a C (or C++, since C++ includes the header) keyword
        s.append(name);
        s.push('_');
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
    return s;
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
        match (this.shape_of(p.ty) ?? shape::VOID) {
            .CLOSURE(i) => {
                args.append(this.c_decl(p.ty, p.name, cpp).as_str());
                args.append(fmt(", void *{}_user", S(p.name)).as_str());
            },
            .TEXT(x) => { args.append(this.c_decl(STR, p.name, cpp).as_str()); },
            default => { args.append(this.c_decl(p.ty, p.name, cpp).as_str()); },
        }
    }
    if (f.params.len == 0) {
        args.append("void");
    }
    return args;
}

attach fn c_decl_handle(this: bind&, s: u32, cpp: bool) -> std::string {
    var d = this.handle_c(s, cpp);
    d.append("it");
    return d;
}

attach fn c_ret(this: bind&, e: entry&, cpp: bool) -> std::string {
    if (e.free_of != null) {
        return S("void");
    }
    return this.c_out(this.c.fi(e.f).ret, cpp);
}

// the declarations both C and C++ share, in an order C accepts: what's only pointed at first
attach fn c_types(this: bind&, cpp: bool, out: std::string&) -> void {
    // the structs and E!T structs, declared first: a function type can name one before it's laid out
    var named: std::vec<std::string> = {};
    for (s&) in this.structs.items() {
        put(&named, this.c_named(this.c.si(*s).name, cpp));
    }
    for (rt&) in this.results.items() {
        put(&named, this.c_named(this.result_name(*rt).as_str(), cpp));
    }
    for (n&) in named.items() {
        if (cpp) {
            out.append(fmt("struct {};\n", copy *n).as_str());
        } else {
            out.append(fmt2("typedef struct {} {};\n", copy *n, copy *n).as_str());
        }
    }
    if (!cpp) {
        for (s&) in this.handles.items() {
            val n = this.c_named(this.c.si(*s).name, false);
            out.append(fmt3("// struct {}: held by a handle, freed with {}\ntypedef struct {} ", S(this.c.si(*s).name), this.free_name(*s), copy n).as_str());
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
                    args.append(this.c_in(*ps.at(k), cpp).as_str());
                }
                out.append(fmt3("\n// a callback: called with the data passed along with it, then {}'s arguments\ntypedef {} (*{})(", this.c.ty_name(*this.closures.at(i)), this.c_prim(r, cpp), this.cb_name(@cast<u32>(i), cpp)).as_str());
                out.append(fmt("{});\n", move args).as_str());
            },
            default => {},
        }
    }
    // a closure Volt gives out: call(self, ...) calls it, drop(self) frees it
    for (i) in 0..this.closures.len {
        if (!has_u32(&this.closures_out, @cast<u32>(i))) {
            continue;
        }
        var n = S("closure");
        n.append_uint(@cast<u64>(i));
        val cn = this.c_named(n.as_str(), cpp);
        if (cpp) {
            out.append(fmt("\n// {}, given out by Volt: call(self, ...) calls it, drop(self) frees it\nstruct ", this.c.ty_name(*this.closures.at(i))).as_str());
            out.append(fmt2("{} {{\n    {} call;\n    void *self;\n    void (*drop)(void *self);\n}};\n", copy cn, this.cb_name(@cast<u32>(i), cpp)).as_str());
        } else {
            out.append(fmt("\n// {}, given out by Volt: call(self, ...) calls it, drop(self) frees it\ntypedef struct {{\n", this.c.ty_name(*this.closures.at(i))).as_str());
            out.append(fmt2("    {} call;\n    void *self;\n    void (*drop)(void *self);\n}} {};\n", this.cb_name(@cast<u32>(i), cpp), copy cn).as_str());
        }
    }
    // a trait's object: its fns' table, the object, and what frees it (null when it's only lent)
    for (t&) in this.traits.items() {
        val tn = this.c.ty_name(*t);
        var vt = this.short(*t);
        vt.append("_vt");
        val vtn = this.c_named(vt.as_str(), cpp);
        var on = this.c_named(this.short(*t).as_str(), cpp);
        if (cpp) {
            on.append("_obj");
            out.append(fmt3("\n// trait {}: a table of its fns and the object they're called on; drop frees the object\n// (null: it's lent)\nstruct {};\nstruct {} {{\n", copy tn, copy vtn, copy on).as_str());
        } else {
            out.append(fmt3("\n// trait {}: a table of its fns and the object they're called on; drop frees the object\n// (null: it's lent)\ntypedef struct {} {};\ntypedef struct {{\n", copy tn, copy vtn, copy vtn).as_str());
        }
        out.append(fmt("    const {} *vt;\n    void *self;\n    void (*drop)(void *self);\n", copy vtn).as_str());
        if (cpp) {
            out.append("};\n");
        } else {
            out.append(fmt("}} {};\n", copy on).as_str());
        }
    }
    // what C holds by value, each after what it holds
    for (lt&) in this.layout.items() {
        match (*this.c.t.get(*lt)) {
            .STRUCT(s) => {
                val info = this.c.si(s);
                out.append(fmt("\nstruct {} {{\n", this.c_named(info.name, cpp)).as_str());
                for (f&) in info.fields.items() {
                    out.append(fmt("    {};\n", this.c_decl(f.ty, f.name, cpp)).as_str());
                }
                out.append("};\n");
            },
            .OPT(x) => {
                val n = this.made_name("opt", x, cpp);
                if (cpp) {
                    out.append(fmt2("\n// a Volt optional: has says whether value is there\nstruct {} {{\n    {} value;\n    bool has;\n}};\n", copy n, this.c_prim(x, cpp)).as_str());
                } else {
                    out.append(fmt2("\n// a Volt optional: has says whether value is there\ntypedef struct {{\n    {} value;\n    bool has;\n}} {};\n", this.c_prim(x, cpp), copy n).as_str());
                }
            },
            .ERR_UNION(e, x) => {
                out.append(fmt("\n// {}: error is 0, or the error's code\n", this.c.ty_name(*lt)).as_str());
                out.append(fmt("struct {} {{\n    uint32_t error;\n", this.c_named(this.result_name(*lt).as_str(), cpp)).as_str());
                match (this.shape_of(x) ?? shape::VOID) {
                    .VOID => {},
                    .CLOSURE(i) => { out.append(fmt2("    {}{};\n", spaced(this.c_out(x, cpp)), S("value")).as_str()); },
                    default => { out.append(fmt("    {};\n", this.c_decl(x, "value", cpp)).as_str()); },
                }
                out.append("};\n");
            },
            default => {},
        }
    }
    // the traits' tables: each fn takes the object first
    for (t&) in this.traits.items() {
        var vt = this.short(*t);
        vt.append("_vt");
        out.append(fmt2("\n// trait {}'s fns, each taking the object first\nstruct {} {{\n", this.c.ty_name(*t), this.c_named(vt.as_str(), cpp)).as_str());
        for (f&) in this.fns_of(*t).items() {
            out.append(fmt("    {};\n", this.c_fn_decl(&f.params, f.ret, f.name, cpp)).as_str());
        }
        out.append("};\n");
    }
}

// trait union t's fns
attach fn fns_of(this: bind&, t: u32) -> std::vec<trait_fn> {
    match (*this.c.t.get(t)) {
        .TRAIT_UNION(u) => { return this.trait_fns(u) ?? {}; },
        default => { return {}; },
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
    if (this.texts.len > 0) {
        out.append(fmt("// the same as volt_text_free, as a function of the library\nvoid {}_text_free(volt_text t);\n", S(this.pkg)).as_str());
    }
    out.append(fmt("\n#ifdef __cplusplus\n}\n#endif\n#endif // {}_H\n", copy guard).as_str());
    return out;
}

// ---------- C++ ----------

// the C++ keywords a Volt name might be
fn cpp_keyword(s: str) -> bool {
    val words: str[] = { "new", "delete", "class", "default", "operator", "template", "this", "virtual", "public", "private", "protected", "friend", "typename", "namespace", "using", "auto", "register", "union", "signed", "unsigned", "char", "int", "long", "short", "float", "double", "bool", "void", "const", "static", "extern", "volatile", "inline", "explicit", "export", "throw", "try", "catch", "switch", "case", "goto", "sizeof", "typedef", "struct", "enum", "return", "if", "else", "while", "do", "for", "break", "continue", "and", "or", "not", "xor", "mutable", "requires", "concept", "asm", "typeid", "constexpr", "consteval", "constinit", "noexcept", "decltype", "nullptr", "true", "false", "alignas", "alignof", "static_assert", "thread_local", "co_await", "co_yield", "co_return", "dynamic_cast", "static_cast", "reinterpret_cast", "const_cast", "wchar_t", "char8_t", "char16_t", "char32_t", "bitand", "bitor", "compl", "and_eq", "or_eq", "xor_eq", "not_eq", "final", "override", "import", "module" };
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
    return n;
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
            var ps: std::vec<u32> = {};
            val r = this.fn_parts(t, &ps);
            val sig = this.cpp_sig(&ps, r);
            ty.append(fmt2("std::function<{}> {}", copy sig, S(name)).as_str());
            arg.append(this.cpp_callback(fmt("(*static_cast<std::function<{}> *>(self))", copy sig), &ps, r).as_str());
            arg.append(fmt(", &{}", S(name)).as_str());
        },
        .TEXT(x) => {
            // owned text in: Volt copies it
            ty.append(fmt("str {}", S(name)).as_str());
            arg.append(name);
        },
        .HANDLE(s) => {
            // a handle given to Volt: the class gives it up
            ty.append(fmt2("{} {}", this.local(this.c.si(s).name), S(name)).as_str());
            arg.append(fmt("{}.release()", S(name)).as_str());
        },
        .TRAIT(i) => {
            val cls = this.short(this.trait_of(t));
            if (this.is_ref(t)) {
                ty.append(fmt2("{} &{}", copy cls, S(name)).as_str());
                arg.append(fmt2("{}_lend({})", copy cls, S(name)).as_str());
            } else {
                ty.append(fmt2("std::unique_ptr<{}> {}", copy cls, S(name)).as_str());
                arg.append(fmt2("{}_give(std::move({}))", copy cls, S(name)).as_str());
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

// the C++ type a callback or a trait's fn takes or gives back (text as std::string, a handle as its
// class, lent as a reference or pointer)
attach fn cb_ty(this: bind&, t: u32) -> std::string {
    val h = this.lent_handle(t);
    if (h) {
        val cls = this.local(this.c.si(h).name);
        if (this.is_ref(t)) {
            return fmt("{} &", move cls);
        }
        return fmt("{} *", move cls);
    }
    match (this.shape_of(t) ?? shape::VOID) {
        .TEXT(x) => { return S("std::string"); },
        .HANDLE(s) => { return this.local(this.c.si(s).name); },
        default => { return this.c_prim(t, true); },
    }
}

// R(A, B): the C++ signature of a closure or a trait's fn
attach fn cpp_sig(this: bind&, ps: std::vec<u32>&, r: u32) -> std::string {
    var sig = this.cb_ty(r);
    sig.push('(');
    for (k) in 0..ps.len {
        if (k > 0) {
            sig.append(", ");
        }
        sig.append(this.cb_ty(*ps.at(k)).as_str());
    }
    sig.push(')');
    return sig;
}

// a C function (a lambda without captures) Volt calls with self first and the C forms of ps: it
// calls target (C++ reaching the callable through self) with C++ values, and gives back r's C form
attach fn cpp_callback(this: bind&, target: std::string, ps: std::vec<u32>&, r: u32) -> std::string {
    var lps = S("void *self");
    var pre: std::string = {};
    var args: std::string = {};
    for (k) in 0..ps.len {
        val p = *ps.at(k);
        val kk = unum(@cast<u64>(k));
        val a = fmt("a{}", copy kk);
        lps.append(fmt2(", {}{}", spaced(this.c_in(p, true)), copy a).as_str());
        if (k > 0) {
            args.append(", ");
        }
        val h = this.lent_handle(p);
        if (h) {
            // a handle Volt lends: a class that never frees it
            pre.append(fmt3("auto b{} = {}::borrow({}); ", copy kk, this.local(this.c.si(h).name), copy a).as_str());
            if (this.is_ref(p)) {
                args.append(fmt("b{}", copy kk).as_str());
            } else {
                args.append(fmt2("({} ? &b{} : nullptr)", copy a, copy kk).as_str());
            }
            continue;
        }
        match (this.shape_of(p) ?? shape::VOID) {
            .TEXT(x) => { args.append(fmt2("std::string((const char *){}.ptr, {}.len)", copy a, copy a).as_str()); },
            .HANDLE(s) => { args.append(fmt2("{}({})", this.local(this.c.si(s).name), copy a).as_str()); },
            default => { args.append(a.as_str()); },
        }
    }
    val call = fmt2("{}({})", move target, move args);
    var body: std::string = {};
    if (r == VOID) {
        body = fmt("{}; ", move call);
    } else {
        match (this.shape_of(r) ?? shape::VOID) {
            .TEXT(x) => { body = fmt("return give_text({}); ", move call); },
            .HANDLE(s) => { body = fmt("return {}.release(); ", move call); },
            default => { body = fmt("return {}; ", move call); },
        }
    }
    return fmt4("[]({}) -> {} {{ {}{}}}", move lps, this.c_out(r, true), move pre, move body);
}

// "T0 a0, T1 a1": C++ params of ps's callback types
attach fn cb_params(this: bind&, ps: std::vec<u32>&) -> std::string {
    var out: std::string = {};
    for (k) in 0..ps.len {
        if (k > 0) {
            out.append(", ");
        }
        out.append(fmt2("{}a{}", spaced(this.cb_ty(*ps.at(k))), unum(@cast<u64>(k))).as_str());
    }
    return out;
}

// C++ calling into Volt with values a0.. of ps's callback types: call (a C function taking self
// first), its result as r's callback type
attach fn cpp_call_in(this: bind&, call: str, self: str, ps: std::vec<u32>&, r: u32) -> std::string {
    var args = S(self);
    for (k) in 0..ps.len {
        val p = *ps.at(k);
        val a = fmt("a{}", unum(@cast<u64>(k)));
        args.append(", ");
        val h = this.lent_handle(p);
        if (h) {
            if (this.is_ref(p)) {
                args.append(fmt("{}.get()", copy a).as_str());
            } else {
                args.append(fmt2("({} ? {}->get() : nullptr)", copy a, copy a).as_str());
            }
            continue;
        }
        match (this.shape_of(p) ?? shape::VOID) {
            .TEXT(x) => { args.append(fmt("str({})", copy a).as_str()); },
            .HANDLE(s) => { args.append(fmt("{}.release()", copy a).as_str()); },
            default => { args.append(a.as_str()); },
        }
    }
    val c = fmt2("{}({})", S(call), move args);
    if (r == VOID) {
        return fmt("{};", move c);
    }
    match (this.shape_of(r) ?? shape::VOID) {
        .TEXT(x) => { return fmt("return take_text({});", move c); },
        .HANDLE(s) => { return fmt2("return {}({});", this.local(this.c.si(s).name), move c); },
        default => { return fmt("return {};", move c); },
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
        .CLOSURE(i) => {
            var ps: std::vec<u32> = {};
            val r = this.fn_parts(t, &ps);
            return fmt("std::function<{}>", this.cpp_sig(&ps, r));
        },
        .TRAIT(i) => { return fmt("std::unique_ptr<{}>", this.short(this.trait_of(t))); },
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
        .CLOSURE(i) => {
            // a closure Volt gave out: freed when the last copy of the std::function goes
            var ps: std::vec<u32> = {};
            val res = this.fn_parts(t, &ps);
            var out = fmt4("{}([o = std::shared_ptr<void>({}.self, {}.drop), call = {}.call](", this.cpp_ret(t), S(r), S(r), S(r));
            out.append(fmt3("{}) -> {} {{ {} }})", this.cb_params(&ps), this.cb_ty(res), this.cpp_call_in("call", "o.get()", &ps, res)).as_str());
            return out;
        },
        .TRAIT(i) => {
            val cls = this.short(this.trait_of(t));
            return fmt3("std::unique_ptr<{}>(new volt_{}({}))", copy cls, copy cls, S(r));
        },
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
    return out;
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
    out.append("#pragma once\n#include <cstddef>\n#include <cstdint>\n#include <cstring>\n#include <functional>\n#include <memory>\n#include <optional>\n#include <stdexcept>\n#include <string>\n#include <string_view>\n#include <utility>\n#include <vector>\n\n");
    out.append(fmt("namespace {} {{\n\n", S(this.pkg)).as_str());
    if (this.uses_str) {
        out.append("// a Volt str: bytes and a length (no terminator)\nstruct str {\n    const uint8_t *ptr;\n    size_t len;\n    str(const char *s) : ptr((const uint8_t *)s), len(std::strlen(s)) {}\n    str(std::string_view s) : ptr((const uint8_t *)s.data()), len(s.size()) {}\n    str(const std::string &s) : ptr((const uint8_t *)s.data()), len(s.size()) {}\n    std::string_view view() const { return {(const char *)ptr, len}; }\n};\n\n");
    }
    if (this.texts.len > 0) {
        out.append("// owned text a Volt function gave out (the wrappers copy it into a std::string and free it)\nstruct text {\n    const uint8_t *ptr;\n    size_t len;\n    void *owner;\n    void (*drop)(void *owner);\n};\n\ninline std::string take_text(text t) {\n    std::string s((const char *)t.ptr, t.len);\n    if (t.drop) {\n        t.drop(t.owner);\n    }\n    return s;\n}\n\n// text C++ gives Volt (a callback's result): Volt frees it when it's done\ninline text give_text(std::string s) {\n    auto *o = new std::string(std::move(s));\n    return text{(const uint8_t *)o->data(), o->size(), o, [](void *p) { delete static_cast<std::string *>(p); }};\n}\n\n");
    }
    // the handles' C types, which the C declarations below point at
    if (this.handles.len > 0) {
        out.append("namespace raw {\n");
        for (s&) in this.handles.items() {
            out.append(fmt("struct {};\n", this.local(this.c.si(*s).name)).as_str());
        }
        out.append("}  // namespace raw\n");
    }
    this.c_types(true, &out);
    // the C functions, as they are
    out.append("\n// the C functions (the wrappers below are easier to use)\nnamespace raw {\n");
    out.append("extern \"C\" {\n");
    for (e&) in ents.items() {
        out.append(fmt3("{}{}({});\n", spaced(this.c_ret(e, true)), copy e.name, this.c_params(e, true)).as_str());
    }
    out.append("}\n}  // namespace raw\n");
    // the traits' classes, declared for the handles' methods
    for (t&) in this.traits.items() {
        out.append(fmt("class {};\n", this.short(*t)).as_str());
    }
    // a class per handle: it owns its handle (or only borrows one Volt lends)
    for (s&) in this.handles.items() {
        val cls = this.local(this.c.si(*s).name);
        out.append(fmt3("\n// struct {}: owns a handle, and frees it when it goes away\nclass {} {{\n    raw::{} *p_;\n    bool own_ = true;\n\npublic:\n", S(this.c.si(*s).name), copy cls, copy cls).as_str());
        out.append(fmt2("    explicit {}(raw::{} *p) : p_(p) {{}}\n", copy cls, copy cls).as_str());
        out.append(fmt3("    {}({} &&o) noexcept : p_(o.p_), own_(o.own_) {{\n        o.p_ = nullptr;\n    }}\n    {} &operator=(", copy cls, copy cls, copy cls).as_str());
        out.append(fmt3("{} &&o) noexcept {{\n        std::swap(p_, o.p_);\n        std::swap(own_, o.own_);\n        return *this;\n    }}\n    {}(const {} &) = delete;\n", copy cls, copy cls, copy cls).as_str());
        out.append(fmt3("    {} &operator=(const {} &) = delete;\n    ~{}() {{\n", copy cls, copy cls, copy cls).as_str());
        out.append(fmt("        if (p_ && own_) {\n            raw::{}(p_);\n        }\n    }\n    raw::", this.free_name(*s)).as_str());
        out.append(fmt("{} *get() const {\n        return p_;\n    }\n", copy cls).as_str());
        out.append(fmt2("    // gives the handle up (to Volt, or to free it yourself)\n    raw::{} *release() {{\n        auto p = p_;\n        p_ = nullptr;\n        return p;\n    }}\n    // a handle Volt lends: never freed through this\n    static {} borrow(raw::", copy cls, copy cls).as_str());
        out.append(fmt2("{} *p) {{\n        {} b(p);\n        b.own_ = false;\n        return b;\n    }}\n", copy cls, copy cls).as_str());
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
                out.append(fmt3("    static {} {}({});\n", this.cpp_ret(info.ret), cpp_member(m), move ps).as_str());
            } else {
                out.append(fmt3("    {} {}({});\n", this.cpp_ret(info.ret), cpp_member(m), move ps).as_str());
            }
        }
        out.append("};\n");
    }
    for (k) in 0..this.traits.len {
        this.cpp_trait(@cast<u32>(k), &out);
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
                out.append(fmt4("\ninline {} {}::{}({}) {{\n", this.cpp_ret(info.ret), copy cls, cpp_member(m), move ps).as_str());
                out.append(this.cpp_body(e.f, move args).as_str());
                out.append("}\n");
            }
        } else {
            out.append(fmt3("\ninline {} {}({}) {{\n", this.cpp_ret(info.ret), this.cpp_fn_name(e.f), move ps).as_str());
            out.append(this.cpp_body(e.f, move args).as_str());
            out.append("}\n");
        }
    }
    out.append(fmt("\n}  // namespace {}\n", S(this.pkg)).as_str());
    return out;
}

// a method's name in its C++ class: get, release and borrow are the class's own
fn cpp_member(m: str) -> std::string {
    var n = cpp_ident(m);
    if (n.as_str() == "get" || n.as_str() == "release" || n.as_str() == "borrow") {
        n.push('_');
    }
    return n;
}

// an export fn's name in C++: a generic's instances are overloads of its name, unless two take the
// same parameters (then each is its C name, sum_i32)
attach fn cpp_fn_name(this: bind&, f: u32) -> std::string {
    val info = this.c.fi(f);
    if (this.c.fn_generics(info.decl).len == 0) {
        return cpp_ident(info.c_name);
    }
    val mine = this.cpp_params_of(f);
    for (g&) in this.exports().items() {
        if (*g != f && this.c.fi(*g).decl == info.decl && this.cpp_params_of(*g).as_str() == mine.as_str()) {
            return cpp_ident(info.c_name);
        }
    }
    return cpp_ident(this.c.fn_decl_of(info.decl)->name);
}

attach fn cpp_params_of(this: bind&, f: u32) -> std::string {
    var ps: std::string = {};
    var args: std::string = {};
    for (p&) in this.c.fi(f).params.items() {
        ps.push(',');
        this.cpp_param(p.ty, p.name, &ps, &args);
    }
    return ps;
}

// trait K in C++: an abstract class (subclass it to hand Volt one), the table that calls a subclass's
// overrides, and volt_T, a T Volt gave out
attach fn cpp_trait(this: bind&, k: u32, out: std::string&) -> void {
    val t = *this.traits.at(k);
    val cls = this.short(t);
    val fns = this.fns_of(t);
    out.append(fmt3("\n// trait {}: subclass it to hand Volt a {} (an override mustn't throw: Volt code doesn't\n// unwind); one Volt gives back is a volt_{}\nclass ", this.c.ty_name(t), copy cls, copy cls).as_str());
    out.append(fmt2("{} {{\npublic:\n    virtual ~{}() = default;\n", copy cls, copy cls).as_str());
    for (f&) in fns.items() {
        out.append(fmt3("    virtual {}{}({}) = 0;\n", spaced(this.cb_ty(f.ret)), cpp_ident(f.name), this.cb_params(&f.params)).as_str());
    }
    out.append("};\n");
    // the table: a C function per fn, calling the override
    out.append(fmt3("\ninline const {}_vt *{}_table() {{\n    static const {}", copy cls, copy cls, copy cls).as_str());
    out.append("_vt vt = {\n");
    for (f&) in fns.items() {
        out.append(fmt("        {},\n", this.cpp_callback(fmt2("static_cast<{} *>(self)->{}", copy cls, cpp_ident(f.name)), &f.params, f.ret)).as_str());
    }
    out.append("    };\n    return &vt;\n}\n");
    out.append(fmt4("\n// lends Volt a {}: Volt never frees it\ninline {}_obj {}_lend({} &o) {{\n", copy cls, copy cls, copy cls, copy cls).as_str());
    out.append(fmt("    return {{{}_table(), &o, nullptr}};\n}}\n", copy cls).as_str());
    out.append(fmt4("\n// gives Volt a {}: Volt deletes it when it's done\ninline {}_obj {}_give(std::unique_ptr<{}> o) {{\n", copy cls, copy cls, copy cls, copy cls).as_str());
    out.append(fmt2("    return {{{}_table(), o.release(), [](void *p) {{ delete static_cast<{} *>(p); }}}};\n}}\n", copy cls, copy cls).as_str());
    // one Volt made
    out.append(fmt4("\n// a {} Volt gave out: calls Volt's, frees it when it goes away\nclass volt_{} final : public {} {{\n    {}_obj o_;\n\npublic:\n", copy cls, copy cls, copy cls, copy cls).as_str());
    out.append(fmt4("    explicit volt_{}({}_obj o) : o_(o) {{}}\n    volt_{}(const volt_{} &) = delete;\n", copy cls, copy cls, copy cls, copy cls).as_str());
    out.append(fmt3("    volt_{} &operator=(const volt_{} &) = delete;\n    ~volt_{}() override {{\n        if (o_.drop) {{\n            o_.drop(o_.self);\n        }}\n    }}\n", copy cls, copy cls, copy cls).as_str());
    for (f&) in fns.items() {
        out.append(fmt3("    {}{}({}) override {{\n", spaced(this.cb_ty(f.ret)), cpp_ident(f.name), this.cb_params(&f.params)).as_str());
        out.append(fmt("        {}\n    }\n", this.cpp_call_in(fmt("o_.vt->{}", cpp_ident(f.name)).as_str(), "o_.self", &f.params, f.ret)).as_str());
    }
    out.append("};\n");
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
    return out;
}

// the struct a pointer parameter points to, when the API takes the struct (and copies it back)
attach fn ref_struct(this: bind&, t: u32) -> u32? {
    match (this.shape_of(t) ?? shape::VOID) {
        .PTR(x) => {
            if (x != VOID) {
                match (this.shape_of(x) ?? shape::VOID) {
                    .STRUCT(s) => { return s; },
                    default => {},
                }
            }
        },
        default => {},
    }
    return null;
}

// can the pointer be null (a T*, not a T&)?
attach fn nullable_ptr(this: bind&, t: u32) -> bool {
    match (*this.c.t.get(t)) {
        .REF(y) => { return false; },
        default => { return true; },
    }
}

// can a value of type t cross as itself (in a list, an optional, a callback): numbers, bool, enums,
// structs
attach fn simple_value(this: bind&, t: u32) -> bool {
    match (this.shape_of(t) ?? shape::VOID) {
        .BOOL => { return true; },
        .INT(k) => { return true; },
        .FLOAT(b) => { return true; },
        .ENUM(e) => { return true; },
        .CODE => { return true; },
        .STRUCT(s) => { return true; },
        default => { return false; },
    }
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
            return s;
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
        .TRAIT(i) => { return fmt("{}_obj", this.short(this.trait_of(t))); },
    }
}

// type t's C form as a parameter: text comes in as a str
attach fn rust_in(this: bind&, t: u32) -> std::string {
    match (this.shape_of(t) ?? shape::VOID) {
        .TEXT(x) => { return S("VoltStr"); },
        default => { return this.rust_ty(t); },
    }
}

// type t's C form as a result: a closure comes out boxed (closureN)
attach fn rust_out(this: bind&, t: u32) -> std::string {
    match (this.shape_of(t) ?? shape::VOID) {
        .CLOSURE(i) => { return fmt("closure{}", unum(@cast<u64>(i))); },
        default => { return this.rust_ty(t); },
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
        s.append(this.rust_in(*ps.at(k)).as_str());
    }
    s.push(')');
    if (r != VOID) {
        s.append(" -> ");
        s.append(this.rust_out(r).as_str());
    }
    return s;
}

// a type a closure or a trait's fn takes or gives in Rust (ctx 0: a parameter; 1: what a Rust
// closure gives Volt back; 2: what a Volt closure gives Rust back; 3: a trait fn's result): text as
// String, a str as &str (a Rust closure's, &'static str; a Volt closure's, a copy as String; a
// trait fn's borrows from the object), a lent handle as &T, an owned one as T, E!T as Result
attach fn rust_cb_ty(this: bind&, t: u32, ctx: u8) -> std::string {
    if (ctx == 0) {
        val h = this.lent_handle(t);
        if (h) {
            return fmt("&{}", this.local(this.c.si(h).name));
        }
    }
    match (this.shape_of(t) ?? shape::VOID) {
        .VOID => { return S("()"); },
        .STR => {
            if (ctx == 0 || ctx == 3) {
                return S("&str");
            }
            if (ctx == 2) {
                return S("String");
            }
            return S("&'static str");
        },
        .TEXT(x) => { return S("String"); },
        .HANDLE(s) => { return this.local(this.c.si(s).name); },
        .RESULT(e, x) => { return fmt("Result<{}, Error>", this.rust_cb_ty(x, ctx)); },
        default => { return this.rust_ty(t); },
    }
}

// FnMut(A, B) -> R: a closure's Rust signature (out: one Volt gives Rust)
attach fn rust_sig(this: bind&, ps: std::vec<u32>&, r: u32, out: bool) -> std::string {
    var s = S("FnMut(");
    for (k) in 0..ps.len {
        if (k > 0) {
            s.append(", ");
        }
        s.append(this.rust_cb_ty(*ps.at(k), 0).as_str());
    }
    s.push(')');
    if (r != VOID) {
        s.append(" -> ");
        var ctx: u8 = 1;
        if (out) {
            ctx = 2;
        }
        s.append(this.rust_cb_ty(r, ctx).as_str());
    }
    return s;
}

// the Rust value of C argument a (of type t) Volt passes to Rust
attach fn rust_from_c(this: bind&, t: u32, a: str) -> std::string {
    val h = this.lent_handle(t);
    if (h) {
        // a handle Volt lends: a value that never frees it
        return fmt2("&*std::mem::ManuallyDrop::new({}::from_raw({}))", this.local(this.c.si(h).name), S(a));
    }
    match (this.shape_of(t) ?? shape::VOID) {
        .STR => { return fmt("unsafe {{ {}.as_str() }}", S(a)); },
        .TEXT(x) => { return fmt("unsafe {{ {}.to_string() }}", S(a)); },
        .HANDLE(s) => { return fmt2("{}::from_raw({})", this.local(this.c.si(s).name), S(a)); },
        default => { return S(a); },
    }
}

// the C form of Rust value r (of type t) Rust gives Volt back
attach fn rust_give(this: bind&, t: u32, r: str) -> std::string {
    match (this.shape_of(t) ?? shape::VOID) {
        .STR => { return fmt("VoltStr::from({})", S(r)); },
        .TEXT(x) => { return fmt("VoltText::give({})", S(r)); },
        .HANDLE(s) => { return fmt("{}.into_raw()", S(r)); },
        .RESULT(e, x) => {
            val rn = this.result_name(t);
            if (x == VOID) {
                return fmt4("match {} {{ Ok(()) => {} {{ error: 0 }}, Err(e) => {} {{ error: e.code }} }}", S(r), copy rn, copy rn, S(""));
            }
            var out = fmt3("match {} {{ Ok(v) => {} {{ error: 0, value: {} }}, ", S(r), copy rn, this.rust_give(x, "v"));
            out.append(fmt("Err(e) => {} { error: e.code, value: unsafe { std::mem::zeroed() } } }", copy rn).as_str());
            return out;
        },
        default => { return S(r); },
    }
}

// the C argument of Rust value a (of type t) Rust passes to Volt
attach fn rust_pass(this: bind&, t: u32, a: str) -> std::string {
    if (this.lent_handle(t)) {
        return fmt("{}.as_raw()", S(a));
    }
    match (this.shape_of(t) ?? shape::VOID) {
        .STR => { return fmt("VoltStr::from({})", S(a)); },
        .TEXT(x) => { return fmt("VoltStr::from({}.as_str())", S(a)); },
        .HANDLE(s) => { return fmt("{}.into_raw()", S(a)); },
        default => { return S(a); },
    }
}

// the Rust value of C result r (of type t) Volt gives Rust back from a closure (lend: from a
// trait's fn, whose str borrows from the object)
attach fn rust_took(this: bind&, t: u32, r: str, lend: bool) -> std::string {
    match (this.shape_of(t) ?? shape::VOID) {
        .STR => {
            if (lend) {
                return fmt("unsafe {{ {}.as_str() }}", S(r));
            }
            return fmt("unsafe {{ {}.to_string() }}", S(r));
        },
        .TEXT(x) => { return fmt("{}.take()", S(r)); },
        .HANDLE(s) => { return fmt2("{}::from_raw({})", this.local(this.c.si(s).name), S(r)); },
        .RESULT(e, x) => {
            if (x == VOID) {
                return fmt("{{ let r = {}; if r.error != 0 {{ Err(Error {{ code: r.error }}) }} else {{ Ok(()) }} }}", S(r));
            }
            return fmt2("{{ let r = {}; if r.error != 0 {{ Err(Error {{ code: r.error }}) }} else {{ Ok({}) }} }}", S(r), this.rust_took(x, "r.value", lend));
        },
        default => { return S(r); },
    }
}

// a C function Volt calls with the caller's data u first and ps' C forms: it calls target (Rust
// reaching the callable through u) with Rust values, and gives back r's C form
attach fn rust_callback(this: bind&, name: str, generics: str, target: str, ps: std::vec<u32>&, r: u32) -> std::string {
    var cps = S("u: *mut std::os::raw::c_void");
    var args: std::string = {};
    for (k) in 0..ps.len {
        val p = *ps.at(k);
        val a = fmt("a{}", unum(@cast<u64>(k)));
        cps.append(fmt2(", {}: {}", copy a, this.rust_in(p)).as_str());
        if (k > 0) {
            args.append(", ");
        }
        args.append(this.rust_from_c(p, a.as_str()).as_str());
    }
    var ret: std::string = {};
    if (r != VOID) {
        ret = fmt(" -> {}", this.rust_out(r));
    }
    val call = fmt2("{}({})", S(target), move args);
    var body = move call;
    if (r != VOID) {
        body = this.rust_give(r, body.as_str());
    }
    var out = fmt4("extern \"C\" fn {}{}({}){}", S(name), S(generics), move cps, move ret);
    out.append(fmt(" {{\n    {}\n}}\n", move body).as_str());
    return out;
}

// Rust calling into Volt: call (a C function, an expression) with self first and Rust values a0..
// of ps; the expression's value is r's Rust value (lend: a trait's fn's)
attach fn rust_call_out(this: bind&, call: str, self: str, ps: std::vec<u32>&, r: u32, lend: bool) -> std::string {
    var args = S(self);
    for (k) in 0..ps.len {
        args.append(", ");
        args.append(this.rust_pass(*ps.at(k), fmt("a{}", unum(@cast<u64>(k))).as_str()).as_str());
    }
    val c = fmt3("unsafe {{ ({})({}) }}{}", S(call), move args, S(""));
    if (r == VOID) {
        return c;
    }
    return this.rust_took(r, c.as_str(), lend);
}

// "a0: A, a1: B": Rust parameters of ps' callback types
attach fn rust_cb_params(this: bind&, ps: std::vec<u32>&) -> std::string {
    var out: std::string = {};
    for (k) in 0..ps.len {
        if (k > 0) {
            out.append(", ");
        }
        out.append(fmt2("a{}: {}", unum(@cast<u64>(k)), this.rust_cb_ty(*ps.at(k), 0)).as_str());
    }
    return out;
}

// a wrapper's parameter in Rust, and the C argument(s) it passes (pre: statements before the call;
// gens: the wrapper's generics, for a closure's type)
attach fn rust_param(this: bind&, t: u32, name: str, ty: std::string&, arg: std::string&, pre: std::string&, gens: std::string&) -> void {
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
        .TEXT(x) => {
            // owned text in: Volt copies it
            ty.append(fmt("{}: &str", copy n).as_str());
            arg.append(fmt("VoltStr::from({})", copy n).as_str());
        },
        .HANDLE(s) => {
            // given to Volt, which frees it
            ty.append(fmt2("{}: {}", copy n, this.local(this.c.si(s).name)).as_str());
            arg.append(fmt("{}.into_raw()", copy n).as_str());
        },
        .TRAIT(i) => {
            val tr = this.short(this.trait_of(t));
            if (this.is_ref(t)) {
                // lent for the call
                ty.append(fmt2("{}: &mut dyn {}", copy n, copy tr).as_str());
                pre.append(fmt3("    let mut {}_r: &mut dyn {} = {};\n", copy n, copy tr, copy n).as_str());
                arg.append(fmt2("{}_lend(&mut {}_r)", copy tr, copy n).as_str());
            } else {
                // given: Volt drops it
                ty.append(fmt2("{}: Box<dyn {}>", copy n, copy tr).as_str());
                arg.append(fmt2("{}_give({})", copy tr, copy n).as_str());
            }
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
            // any Rust closure (a generic F_name): a C function calls it through the caller's data
            var ps: std::vec<u32> = {};
            val r = this.fn_parts(t, &ps);
            val g = fmt("F_{}", S(name));
            val sig = this.rust_sig(&ps, r, false);
            if (gens.len() > 0) {
                gens.append(", ");
            }
            gens.append(fmt2("{}: {}", copy g, copy sig).as_str());
            ty.append(fmt2("mut {}: {}", copy n, copy g).as_str());
            val cb = this.rust_callback(fmt("call_{}", S(name)).as_str(), fmt("<F: {}>", copy sig).as_str(), "(unsafe { &mut *(u as *mut F) })", &ps, r);
            pre.append(indent(cb.as_str()).as_str());
            arg.append(fmt4("call_{}::<{}>, &mut {} as *mut {} as *mut std::os::raw::c_void", S(name), copy g, copy n, copy g).as_str());
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
        .TRAIT(i) => { return fmt("Box<dyn {}>", this.short(this.trait_of(t))); },
        .CLOSURE(i) => {
            var ps: std::vec<u32> = {};
            val r = this.fn_parts(t, &ps);
            return fmt("Box<dyn {}>", this.rust_sig(&ps, r, true));
        },
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
        .TRAIT(i) => { return fmt2("Box::new(volt_{}({}))", this.short(this.trait_of(t)), S(r)); },
        .CLOSURE(i) => {
            // a closure Volt gave out: freed when the Box goes (o, captured whole)
            var ps: std::vec<u32> = {};
            val res = this.fn_parts(t, &ps);
            var out = fmt2("{{ let c = {}; let o = VoltOwned {{ self_: c.self_, drop: c.drop }}; let call = c.call; Box::new(move |{}| ", S(r), this.rust_cb_params(&ps));
            out.append(fmt("{{ let o = &o; {} }}) }}", this.rust_call_out("call", "o.self_", &ps, res, false)).as_str());
            return out;
        },
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
    return out;
}

// trait K in Rust: a Rust trait (implement it to hand Volt one: lent as &mut dyn T, given as
// Box<dyn T>), the table calling a Rust object's fns, and volt_T, a T Volt gave out
attach fn rust_trait(this: bind&, k: u32, out: std::string&) -> void {
    val t = *this.traits.at(k);
    val tr = this.short(t);
    val fns = this.fns_of(t);
    out.append(fmt4("\n/// trait {}: implement it to hand Volt a {} (lent: &mut dyn {}; given: Box<dyn {}>,\n", this.c.ty_name(t), copy tr, copy tr, copy tr).as_str());
    out.append(fmt2("/// which Volt drops); one Volt gives back is a volt_{}\npub trait {} {{\n", copy tr, copy tr).as_str());
    for (f&) in fns.items() {
        var ps = S("&mut self");
        val cps = this.rust_cb_params(&f.params);
        if (cps.len() > 0) {
            ps.append(", ");
            ps.append(cps.as_str());
        }
        var ret: std::string = {};
        if (f.ret != VOID) {
            ret = fmt(" -> {}", this.rust_cb_ty(f.ret, 3));
        }
        out.append(fmt3("    fn {}({}){};\n", rust_ident(f.name), move ps, move ret).as_str());
    }
    out.append("}\n");
    // the table, in a module of its own: a C function per fn, calling the Rust object's (the object
    // is a &mut dyn T)
    var table: std::string = {};
    out.append(fmt("\nmod {}__table {{\n    use super::*;\n", copy tr).as_str());
    for (f&) in fns.items() {
        out.append("\n");
        out.append(indent(this.rust_callback(S(f.name).as_str(), "", fmt2("(unsafe {{ &mut **(u as *mut &mut dyn {}) }}).{}", copy tr, rust_ident(f.name)).as_str(), &f.params, f.ret).as_str()).as_str());
        table.append(fmt2("{}: {}, ", rust_ident(f.name), rust_ident(f.name)).as_str());
    }
    out.append(fmt3("\n    pub static TABLE: {}_vt = {}_vt {{ {}}};\n}}\n", copy tr, copy tr, move table).as_str());
    out.append(fmt4("\n/// lends Volt a {}: Volt never frees it\npub fn {}_lend(s: &mut &mut dyn {}) -> {}_obj {{\n", copy tr, copy tr, copy tr, copy tr).as_str());
    out.append(fmt3("    {}_obj {{ vt: &{}__table::TABLE, self_: s as *mut &mut dyn {} as *mut std::os::raw::c_void, drop: None }}\n}}\n", copy tr, copy tr, copy tr).as_str());
    out.append(fmt4("\n/// gives Volt a {}: Volt drops it when it's done\npub fn {}_give(s: Box<dyn {}>) -> {}_obj {{\n", copy tr, copy tr, copy tr, copy tr).as_str());
    out.append(fmt2("    extern \"C\" fn drop_it(o: *mut std::os::raw::c_void) {{\n        unsafe {{\n            let r = Box::from_raw(o as *mut &mut dyn {});\n            drop(Box::from_raw(*r as *mut dyn {}));\n        }}\n    }}\n", copy tr, copy tr).as_str());
    out.append(fmt3("    let r: &'static mut dyn {} = Box::leak(s);\n    {}_obj {{ vt: &{}__table::TABLE, self_: Box::into_raw(Box::new(r)) as *mut std::os::raw::c_void, drop: Some(drop_it) }}\n}}\n", copy tr, copy tr, copy tr).as_str());
    // one Volt made
    out.append(fmt4("\n/// a {} Volt gave out: calls Volt's, which is freed when this is dropped\npub struct volt_{}({}_obj);\n\nimpl Drop for volt_{} {{\n", copy tr, copy tr, copy tr, copy tr).as_str());
    out.append("    fn drop(&mut self) {\n        if let Some(d) = self.0.drop {\n            d(self.0.self_);\n        }\n    }\n}\n");
    out.append(fmt2("\nimpl {} for volt_{} {{\n", copy tr, copy tr).as_str());
    for (f&) in fns.items() {
        var ps = S("&mut self");
        val cps = this.rust_cb_params(&f.params);
        if (cps.len() > 0) {
            ps.append(", ");
            ps.append(cps.as_str());
        }
        var ret: std::string = {};
        if (f.ret != VOID) {
            ret = fmt(" -> {}", this.rust_cb_ty(f.ret, 3));
        }
        out.append(fmt3("    fn {}({}){} {{\n", rust_ident(f.name), move ps, move ret).as_str());
        out.append(fmt("        {}\n    }\n", this.rust_call_out(fmt("(*self.0.vt).{}", rust_ident(f.name)).as_str(), "self.0.self_", &f.params, f.ret, true)).as_str());
    }
    out.append("}\n");
}

attach fn rust_text(this: bind&) -> std::string {
    val ents = this.entries();
    var out: std::string = {};
    out.append(fmt("// {}: generated by voltc bindings; the Volt package for Rust. Link the library\n", S(this.pkg)).as_str());
    out.append("// yourself (-l NAME, or #[link] in a build script): shared or static. Module raw has the C\n// functions; the functions and types here wrap them (errors come back as Err(Error)).\n");
    out.append("#![allow(non_camel_case_types, non_upper_case_globals, non_snake_case, dead_code, unused_mut, unused_unsafe, clippy::all)]\n");
    if (this.uses_str || this.texts.len > 0) {
        out.append("\n/// a Volt str: bytes and a length (no terminator)\n#[repr(C)]\n#[derive(Clone, Copy, Debug)]\npub struct VoltStr {\n    pub ptr: *const u8,\n    pub len: usize,\n}\n\nimpl VoltStr {\n    pub fn from(s: &str) -> VoltStr {\n        VoltStr { ptr: s.as_ptr(), len: s.len() }\n    }\n    /// the bytes (valid as long as what the str points into)\n    pub unsafe fn bytes<'a>(self) -> &'a [u8] {\n        if self.len == 0 {\n            return &[];\n        }\n        std::slice::from_raw_parts(self.ptr, self.len)\n    }\n    /// the text (valid as long as what the str points into; bytes that aren't UTF-8 end it)\n    pub unsafe fn as_str<'a>(self) -> &'a str {\n        let b = self.bytes();\n        match std::str::from_utf8(b) {\n            Ok(s) => s,\n            Err(e) => std::str::from_utf8_unchecked(&b[..e.valid_up_to()]),\n        }\n    }\n    /// a copy of the text\n    pub unsafe fn to_string(self) -> String {\n        String::from_utf8_lossy(self.bytes()).into_owned()\n    }\n}\n");
    }
    if (this.texts.len > 0) {
        out.append("\n/// owned text a Volt function gave out: take() copies it into a String and frees it\n#[repr(C)]\npub struct VoltText {\n    pub ptr: *const u8,\n    pub len: usize,\n    pub owner: *mut std::os::raw::c_void,\n    pub drop: Option<extern \"C\" fn(*mut std::os::raw::c_void)>,\n}\n\nimpl VoltText {\n    pub fn take(self) -> String {\n        let s = if self.len == 0 { String::new() } else { unsafe { String::from_utf8_lossy(std::slice::from_raw_parts(self.ptr, self.len)).into_owned() } };\n        if let Some(d) = self.drop {\n            d(self.owner);\n        }\n        s\n    }\n    /// text Rust gives Volt (a callback's result): Volt frees it when it's done\n    pub fn give(s: String) -> VoltText {\n        extern \"C\" fn drop_it(o: *mut std::os::raw::c_void) {\n            unsafe { drop(Box::from_raw(o as *mut String)) }\n        }\n        let b = Box::new(s);\n        VoltText { ptr: b.as_ptr(), len: b.len(), owner: Box::into_raw(b) as *mut std::os::raw::c_void, drop: Some(drop_it) }\n    }\n}\n");
    }
    if (this.closures_out.len > 0) {
        out.append("\n/// a value Volt gave out (a closure's data): dropping this frees it\npub struct VoltOwned {\n    pub self_: *mut std::os::raw::c_void,\n    pub drop: Option<extern \"C\" fn(*mut std::os::raw::c_void)>,\n}\n\nimpl Drop for VoltOwned {\n    fn drop(&mut self) {\n        if let Some(d) = self.drop {\n            d(self.self_);\n        }\n    }\n}\n");
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
                    out.append(fmt("    pub value: {},\n", this.rust_out(x)).as_str());
                }
                out.append("}\n");
            },
            default => {},
        }
    }
    // a closure Volt gives out: call(self_, ...) calls it, drop(self_) frees it
    for (i) in 0..this.closures.len {
        if (!has_u32(&this.closures_out, @cast<u32>(i))) {
            continue;
        }
        out.append(fmt3("\n/// {}, given out by Volt: call(self_, ...) calls it, drop(self_) frees it\n#[repr(C)]\npub struct closure{} {{\n    pub call: {},\n", this.c.ty_name(*this.closures.at(i)), unum(@cast<u64>(i)), this.rust_fn_ty(*this.closures.at(i), true)).as_str());
        out.append("    pub self_: *mut std::os::raw::c_void,\n    pub drop: Option<extern \"C\" fn(*mut std::os::raw::c_void)>,\n}\n");
    }
    // a trait's object (its fns' table and the object; drop: None when it's lent) and table
    for (t&) in this.traits.items() {
        val tr = this.short(*t);
        out.append(fmt4("\n/// trait {}: a table of its fns and the object they're called on; drop frees the object\n/// (None: it's lent)\n#[repr(C)]\npub struct {}_obj {{\n    pub vt: *const {}_vt,\n{}", this.c.ty_name(*t), copy tr, copy tr, S("")).as_str());
        out.append("    pub self_: *mut std::os::raw::c_void,\n    pub drop: Option<extern \"C\" fn(*mut std::os::raw::c_void)>,\n}\n");
        out.append(fmt2("\n/// trait {}'s fns, each taking the object first\n#[repr(C)]\npub struct {}_vt {{\n", this.c.ty_name(*t), copy tr).as_str());
        for (f&) in this.fns_of(*t).items() {
            var s = S("extern \"C\" fn(*mut std::os::raw::c_void");
            for (p&) in f.params.items() {
                s.append(", ");
                s.append(this.rust_in(*p).as_str());
            }
            s.push(')');
            if (f.ret != VOID) {
                s.append(" -> ");
                s.append(this.rust_out(f.ret).as_str());
            }
            out.append(fmt2("    pub {}: {},\n", rust_ident(f.name), move s).as_str());
        }
        out.append("}\n");
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
            args.append(fmt2("{}: {}", rust_ident(p.name), this.rust_in(p.ty)).as_str());
            match (this.shape_of(p.ty) ?? shape::VOID) {
                .CLOSURE(i) => { args.append(fmt(", {}_user: *mut std::os::raw::c_void", S(p.name)).as_str()); },
                default => {},
            }
        }
        var ret: std::string = {};
        if (f.ret != VOID) {
            ret = fmt(" -> {}", this.rust_out(f.ret));
        }
        out.append(fmt3("        pub fn {}({}){};\n", copy e.name, move args, move ret).as_str());
    }
    out.append("    }\n}\n");
    for (k) in 0..this.traits.len {
        this.rust_trait(@cast<u32>(k), &out);
    }
    // a type per export struct: it owns its handle
    for (s&) in this.handles.items() {
        val cls = this.local(this.c.si(*s).name);
        out.append(fmt4("\n/// export struct {}: owns a handle, and frees it when dropped\npub struct {} {{\n    raw: *mut raw::{},\n}}\n\nimpl Drop for {} {{\n", S(this.c.si(*s).name), copy cls, copy cls, copy cls).as_str());
        out.append(fmt("    fn drop(&mut self) {\n        if !self.raw.is_null() {\n            unsafe { raw::{}(self.raw) }\n        }\n    }\n}\n", this.free_name(*s)).as_str());
        out.append(fmt3("\nimpl {} {{\n    /// takes ownership of a handle an export fn returned\n    pub fn from_raw(raw: *mut raw::{}) -> {} {{\n", copy cls, copy cls, copy cls).as_str());
        out.append(fmt2("        {} {{ raw }}\n    }}\n    pub fn as_raw(&self) -> *mut raw::{} {{\n        self.raw\n    }}\n", copy cls, copy cls).as_str());
        out.append(fmt("    /// gives the handle up (to Volt, or to free it yourself)\n    pub fn into_raw(self) -> *mut raw::{} {{\n        let r = self.raw;\n        std::mem::forget(self);\n        r\n    }}\n", copy cls).as_str());
        for (e&) in ents.items() {
            if (e.free_of != null) {
                continue;
            }
            val m = this.member_of(e.f, *s) ?? continue;
            val info = this.c.fi(e.f);
            var ps: std::string = {};
            var args: std::string = {};
            var pre: std::string = {};
            var gens: std::string = {};
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
                this.rust_param(info.params.at(k).ty, info.params.at(k).name, &ps, &args, &pre, &gens);
            }
            if (gens.len() > 0) {
                gens = fmt("<{}>", move gens);
            }
            out.append(fmt4("    pub fn {}{}({}) -> {} {{\n", rust_ident(m), move gens, move ps, this.rust_ret(info.ret)).as_str());
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
        var gens: std::string = {};
        for (p&) in info.params.items() {
            if (ps.len() > 0) {
                ps.append(", ");
                args.append(", ");
            }
            this.rust_param(p.ty, p.name, &ps, &args, &pre, &gens);
        }
        if (gens.len() > 0) {
            gens = fmt("<{}>", move gens);
        }
        out.append(fmt4("\npub fn {}{}({}) -> {} {{\n", rust_ident(info.c_name), move gens, move ps, this.rust_ret(info.ret)).as_str());
        out.append(this.rust_body(e.f, move args, move pre).as_str());
        out.append("}\n");
    }
    return out;
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
            return s;
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
        .TRAIT(i) => { return fmt("{}_obj", this.short(this.trait_of(t))); },
    }
}

// type t's C form as a parameter: text comes in as a str
attach fn zig_in(this: bind&, t: u32) -> std::string {
    match (this.shape_of(t) ?? shape::VOID) {
        .TEXT(x) => { return S("VoltStr"); },
        default => { return this.zig_ty(t); },
    }
}

// type t's C form as a result: a closure comes out boxed (closureN)
attach fn zig_out(this: bind&, t: u32) -> std::string {
    match (this.shape_of(t) ?? shape::VOID) {
        .CLOSURE(i) => { return fmt("closure{}", unum(@cast<u64>(i))); },
        default => { return this.zig_ty(t); },
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
        s.append(this.zig_in(*ps.at(k)).as_str());
    }
    s.append(") callconv(.c) ");
    s.append(this.zig_out(r).as_str());
    return s;
}

// Zig doesn't let a parameter shadow a declaration: a name the file declares gets a _
attach fn zig_name(this: bind&, name: str) -> std::string {
    var taken = name == "std" || name == "raw" || name == "Error" || name == "err_of" || name == "code_of" || name == "self" || name == "print";
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
    for (t&) in this.traits.items() {
        val tr = this.short(*t);
        val suffixes: str[] = { "_table", "_lend", "_give", "_obj", "_vt" };
        for (suffix) in suffixes {
            if (name == fmt2("{}{}", copy tr, S(suffix)).as_str()) {
                taken = true;
            }
        }
        if (name == fmt("volt_{}", copy tr).as_str()) {
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
    return n;
}

// what a closure or a trait's fn takes or gives in Zig (ctx 0: a parameter; 1: what Zig gives
// Volt back; 2: what Volt gives Zig back): text as []const u8 (Volt's, owned, a VoltText), a lent
// handle or an owned one as its type, E!T as Error!T
attach fn zig_cb_ty(this: bind&, t: u32, ctx: u8) -> std::string {
    if (ctx == 0) {
        val h = this.lent_handle(t);
        if (h) {
            return this.local(this.c.si(h).name);
        }
    }
    match (this.shape_of(t) ?? shape::VOID) {
        .VOID => { return S("void"); },
        .STR => { return S("[]const u8"); },
        .TEXT(x) => {
            if (ctx == 2) {
                return S("VoltText");
            }
            return S("[]const u8");
        },
        .HANDLE(s) => { return this.local(this.c.si(s).name); },
        .RESULT(e, x) => { return fmt("Error!{}", this.zig_cb_ty(x, ctx)); },
        default => { return this.zig_ty(t); },
    }
}

// the Zig value of C argument a (of type t) Volt passes to Zig
attach fn zig_from_c(this: bind&, t: u32, a: str) -> std::string {
    val h = this.lent_handle(t);
    if (h) {
        return fmt2("{}{{ .raw = {} }}", this.local(this.c.si(h).name), S(a));
    }
    match (this.shape_of(t) ?? shape::VOID) {
        .STR => { return fmt("{}.slice()", S(a)); },
        .TEXT(x) => { return fmt("{}.slice()", S(a)); },
        .HANDLE(s) => { return fmt2("{}{{ .raw = {} }}", this.local(this.c.si(s).name), S(a)); },
        default => { return S(a); },
    }
}

// the C form of Zig value r (of type t) Zig gives Volt back
attach fn zig_give(this: bind&, t: u32, r: str) -> std::string {
    match (this.shape_of(t) ?? shape::VOID) {
        .STR => { return fmt("VoltStr.from({})", S(r)); },
        .TEXT(x) => { return fmt("VoltText.give({})", S(r)); },
        .HANDLE(s) => { return fmt("{}.raw", S(r)); },
        .RESULT(e, x) => {
            val rn = this.result_name(t);
            if (x == VOID) {
                return fmt4("if ({}) |_| {}{{ .@\"error\" = 0 }} else |e| {}{{ .@\"error\" = code_of(e) }}", S(r), copy rn, copy rn, S(""));
            }
            var out = fmt3("if ({}) |v| {}{{ .@\"error\" = 0, .value = {} }} ", S(r), copy rn, this.zig_give(x, "v"));
            out.append(fmt("else |e| {}{{ .@\"error\" = code_of(e), .value = undefined }}", copy rn).as_str());
            return out;
        },
        default => { return S(r); },
    }
}

// the C argument of Zig value a (of type t) Zig passes to Volt
attach fn zig_pass(this: bind&, t: u32, a: str) -> std::string {
    if (this.lent_handle(t)) {
        return fmt("{}.raw", S(a));
    }
    match (this.shape_of(t) ?? shape::VOID) {
        .STR => { return fmt("VoltStr.from({})", S(a)); },
        .TEXT(x) => { return fmt("VoltStr.from({})", S(a)); },
        .HANDLE(s) => { return fmt("{}.raw", S(a)); },
        default => { return S(a); },
    }
}

// the Zig value of C result r (of type t) Volt gives Zig back from a closure or a trait's fn
attach fn zig_took(this: bind&, t: u32, r: str) -> std::string {
    match (this.shape_of(t) ?? shape::VOID) {
        .STR => { return fmt("{}.slice()", S(r)); },
        .HANDLE(s) => { return fmt2("{}{{ .raw = {} }}", this.local(this.c.si(s).name), S(r)); },
        .RESULT(e, x) => {
            if (x == VOID) {
                return fmt("blk: {{\n            const q = {};\n            if (q.@\"error\" != 0) break :blk err_of(q.@\"error\");\n            break :blk {{}};\n        }}", S(r));
            }
            return fmt2("blk: {{\n            const q = {};\n            if (q.@\"error\" != 0) break :blk err_of(q.@\"error\");\n            break :blk {};\n        }}", S(r), this.zig_took(x, "q.value"));
        },
        default => { return S(r); },
    }
}

// "a0: A, a1: B": Zig parameters of ps' callback types
attach fn zig_cb_params(this: bind&, ps: std::vec<u32>&) -> std::string {
    var out: std::string = {};
    for (k) in 0..ps.len {
        out.append(fmt2(", a{}: {}", unum(@cast<u64>(k)), this.zig_cb_ty(*ps.at(k), 0)).as_str());
    }
    return out;
}

// the C function Volt calls with the data u first and ps' C forms: `target` is the call's callee
// (reaching the callable through u, with get first: its statements), called with Zig values; it
// gives back r's C form
attach fn zig_callback(this: bind&, name: str, get: str, target: str, first: str, ps: std::vec<u32>&, r: u32) -> std::string {
    var cps = S("u: ?*anyopaque");
    var args = S(first);
    for (k) in 0..ps.len {
        val p = *ps.at(k);
        val a = fmt("a{}", unum(@cast<u64>(k)));
        cps.append(fmt2(", {}: {}", copy a, this.zig_in(p)).as_str());
        if (args.len() > 0) {
            args.append(", ");
        }
        args.append(this.zig_from_c(p, a.as_str()).as_str());
    }
    val call = fmt2("{}({})", S(target), move args);
    var body: std::string = {};
    if (r == VOID) {
        body = fmt("{};", move call);
    } else {
        body = fmt("return {};", this.zig_give(r, call.as_str()));
    }
    var out = fmt4("fn {}({}) callconv(.c) {} {{\n    {}", S(name), move cps, this.zig_out(r), S(get));
    out.append(fmt("    {}\n}}\n", move body).as_str());
    return out;
}

// Zig calling into Volt: call (a C function, an expression) with self first and Zig values a0..
// of ps, as a statement returning r's Zig value
attach fn zig_call_out(this: bind&, call: str, self: str, ps: std::vec<u32>&, r: u32) -> std::string {
    var args = S(self);
    for (k) in 0..ps.len {
        args.append(", ");
        args.append(this.zig_pass(*ps.at(k), fmt("a{}", unum(@cast<u64>(k))).as_str()).as_str());
    }
    val c = fmt2("{}({})", S(call), move args);
    if (r == VOID) {
        return fmt("{};", move c);
    }
    return fmt("return {};", this.zig_took(r, c.as_str()));
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
        .TEXT(x) => {
            // owned text in: Volt copies it
            ty.append(fmt("{}: []const u8", S(name)).as_str());
            arg.append(fmt("VoltStr.from({})", S(name)).as_str());
        },
        .HANDLE(s) => {
            // given to Volt, which frees it (don't deinit it after)
            ty.append(fmt2("{}: {}", S(name), this.local(this.c.si(s).name)).as_str());
            arg.append(fmt("{}.raw", S(name)).as_str());
        },
        .TRAIT(i) => {
            val tr = this.short(this.trait_of(t));
            ty.append(fmt("{}: anytype", S(name)).as_str());
            if (this.is_ref(t)) {
                // a pointer to any type with the trait's fns, lent for the call
                arg.append(fmt2("{}_lend({})", copy tr, S(name)).as_str());
            } else {
                // a value of any type with the trait's fns, given: Volt deinits and frees it
                arg.append(fmt2("{}_give({})", copy tr, S(name)).as_str());
            }
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
            // context is passed to f with each call: f(context, args...)
            var ps: std::vec<u32> = {};
            val r = this.fn_parts(t, &ps);
            var fps = fmt("@TypeOf({}_context)", S(name));
            for (k) in 0..ps.len {
                fps.append(", ");
                fps.append(this.zig_cb_ty(*ps.at(k), 0).as_str());
            }
            ty.append(fmt4("{}_context: anytype, comptime {}: fn ({}) {}", S(name), S(name), move fps, this.zig_cb_ty(r, 1)).as_str());
            val get = fmt2("const ctx: *const @TypeOf({}_context) = @ptrCast(@alignCast(u));\n{}", S(name), S("    "));
            val cb = this.zig_callback("call", get.as_str(), name, "ctx.*", &ps, r);
            pre.append(fmt2("    const {}_call = struct {{\n{}    }};\n", S(name), indent_n(cb.as_str(), 8)).as_str());
            arg.append(fmt2("{}_call.call, @ptrCast(@constCast(&{}_context))", S(name), S(name)).as_str());
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
        .TRAIT(i) => { return fmt("volt_{}", this.short(this.trait_of(t))); },
        .CLOSURE(i) => { return fmt("fn{}", unum(@cast<u64>(i))); },
        default => { return this.zig_ty(t); },
    }
}

attach fn zig_value(this: bind&, t: u32, r: str) -> std::string {
    match (this.shape_of(t) ?? shape::VOID) {
        .STR => { return fmt("{}.slice()", S(r)); },
        .HANDLE(s) => { return fmt2("{}{{ .raw = {} }}", this.local(this.c.si(s).name), S(r)); },
        .OPT(x) => { return fmt("{}.get()", S(r)); },
        .TRAIT(i) => { return fmt2("volt_{}{{ .o = {} }}", this.short(this.trait_of(t)), S(r)); },
        .CLOSURE(i) => { return fmt2("fn{}{{ .c = {} }}", unum(@cast<u64>(i)), S(r)); },
        default => { return S(r); },
    }
}

attach fn zig_body(this: bind&, f: u32, args: std::string, pre: std::string) -> std::string {
    val info = this.c.fi(f);
    var out = move pre;
    if (info.ret == VOID) {
        out.append(fmt2("    raw.{}({});\n", S(info.c_name), move args).as_str());
        return out;
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
    return out;
}

// trait K in Zig: any type with its fns passes where Volt takes one (T_lend a pointer, T_give a
// value Volt deinits and frees); the table is made per type at comptime; volt_T is one Volt made
attach fn zig_trait(this: bind&, k: u32, out: std::string&) -> void {
    val t = *this.traits.at(k);
    val tr = this.short(t);
    val fns = this.fns_of(t);
    var names: std::string = {};
    for (f&) in fns.items() {
        if (names.len() > 0) {
            names.append(", ");
        }
        names.append(f.name);
    }
    out.append(fmt4("\n/// trait {}: any type with its fns ({}) passes where Volt takes one: lent ({}_lend(&x)),\n", this.c.ty_name(t), move names, copy tr, S("")).as_str());
    out.append(fmt2("/// or given ({}_give(x): Volt calls its deinit, if it has one, and frees it); one Volt gives\n/// back is a volt_{}\n", copy tr, copy tr).as_str());
    out.append(fmt3("pub fn {}_table(comptime T: type) *const {}_vt {{\n    const t = struct {{\n", copy tr, copy tr, S("")).as_str());
    var table: std::string = {};
    for (f&) in fns.items() {
        val cb = this.zig_callback(f.name, "const o: *T = @ptrCast(@alignCast(u));\n    ", fmt("o.{}", S(f.name)).as_str(), "", &f.params, f.ret);
        out.append(indent_n(cb.as_str(), 8).as_str());
        table.append(fmt2(" .{} = {},", S(f.name), S(f.name)).as_str());
    }
    out.append(fmt2("        const vt = {}_vt{{{} }};\n    }};\n    return &t.vt;\n}}\n", copy tr, move table).as_str());
    out.append(fmt4("\npub fn {}_lend(o: anytype) {}_obj {{\n    return .{{ .vt = {}_table(@TypeOf(o.*)), .self = o, .drop = null }};\n}}\n", copy tr, copy tr, copy tr, S("")).as_str());
    out.append(fmt2("\npub fn {}_give(v: anytype) {}_obj {{\n    const T = @TypeOf(v);\n    const p = std.heap.c_allocator.create(T) catch @panic(\"out of memory\");\n    p.* = v;\n", copy tr, copy tr).as_str());
    out.append("    const d = struct {\n        fn drop(u: ?*anyopaque) callconv(.c) void {\n            const q: *T = @ptrCast(@alignCast(u));\n            if (@hasDecl(T, \"deinit\")) q.deinit();\n            std.heap.c_allocator.destroy(q);\n        }\n    };\n");
    out.append(fmt("    return .{{ .vt = {}_table(T), .self = p, .drop = d.drop }};\n}}\n", copy tr).as_str());
    // one Volt made
    out.append(fmt4("\n/// a {} Volt gave out: calls Volt's; deinit() frees it\npub const volt_{} = struct {{\n    o: {}_obj,\n{}", copy tr, copy tr, copy tr, S("")).as_str());
    for (f&) in fns.items() {
        var ret = S("void");
        if (f.ret != VOID) {
            ret = this.zig_cb_ty(f.ret, 2);
        }
        out.append(fmt4("\n    pub fn {}(self: *volt_{}{}) {} {{\n", S(f.name), copy tr, this.zig_cb_params(&f.params), move ret).as_str());
        out.append(fmt("        {}\n    }\n", this.zig_call_out(fmt("self.o.vt.{}", S(f.name)).as_str(), "self.o.self", &f.params, f.ret)).as_str());
    }
    out.append(fmt("\n    pub fn deinit(self: *volt_{}) void {{\n        if (self.o.drop) |d| d(self.o.self);\n    }}\n}};\n", copy tr).as_str());
}

attach fn zig_text(this: bind&) -> std::string {
    val ents = this.entries();
    var out: std::string = {};
    out.append(fmt("// {}: generated by voltc bindings; the Volt package for Zig. Struct raw has the C\n", S(this.pkg)).as_str());
    out.append("// functions; the functions and types here wrap them (errors come back as Error).\nconst std = @import(\"std\");\n");
    if (this.uses_str || this.texts.len > 0) {
        out.append("\n/// a Volt str: bytes and a length (no terminator)\npub const VoltStr = extern struct {\n    ptr: [*]const u8,\n    len: usize,\n    pub fn from(s: []const u8) VoltStr {\n        return .{ .ptr = s.ptr, .len = s.len };\n    }\n    pub fn slice(self: VoltStr) []const u8 {\n        return self.ptr[0..self.len];\n    }\n};\n");
    }
    if (this.texts.len > 0) {
        out.append("\n/// owned text a Volt function gave out: bytes(), then deinit() to free it\npub const VoltText = extern struct {\n    ptr: [*]const u8,\n    len: usize,\n    owner: ?*anyopaque,\n    drop: ?*const fn (?*anyopaque) callconv(.c) void,\n    pub fn bytes(self: VoltText) []const u8 {\n        return self.ptr[0..self.len];\n    }\n    pub fn deinit(self: VoltText) void {\n        if (self.drop) |d| d(self.owner);\n    }\n");
        out.append("    /// text Zig gives Volt (a callback's result): a copy, which Volt frees (a VoltText goes as it is)\n    pub fn give(v: anytype) VoltText {\n        if (@TypeOf(v) == VoltText) return v;\n        const Owned = struct { b: []u8 };\n        const o = std.heap.c_allocator.create(Owned) catch @panic(\"out of memory\");\n        o.b = std.heap.c_allocator.dupe(u8, v) catch @panic(\"out of memory\");\n        const d = struct {\n            fn drop(p: ?*anyopaque) callconv(.c) void {\n                const q: *Owned = @ptrCast(@alignCast(p));\n                std.heap.c_allocator.free(q.b);\n                std.heap.c_allocator.destroy(q);\n            }\n        };\n        return .{ .ptr = o.b.ptr, .len = o.b.len, .owner = o, .drop = d.drop };\n    }\n};\n");
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
        out.append("        else => error.Unknown,\n    };\n}\n\n/// an error's code, for Volt (a callback's error)\npub fn code_of(e: Error) u32 {\n    return switch (e) {\n");
        for (c&) in codes.items() {
            out.append(fmt2("        error.{} => {},\n", S(c.name), num(c.code)).as_str());
        }
        out.append("        error.Unknown => 0xffffffff,\n    };\n}\n");
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
                    out.append(fmt("    value: {},\n", this.zig_out(x)).as_str());
                }
                out.append("};\n");
            },
            default => {},
        }
    }
    // a closure Volt gives out: the C struct, and fnN, which calls it (call) and frees it (deinit)
    for (i) in 0..this.closures.len {
        if (!has_u32(&this.closures_out, @cast<u32>(i))) {
            continue;
        }
        val ct = *this.closures.at(i);
        val ki = unum(@cast<u64>(i));
        out.append(fmt3("\n/// {}, given out by Volt: call(self, ...) calls it, drop(self) frees it\npub const closure{} = extern struct {{\n    call: {},\n", this.c.ty_name(ct), copy ki, this.zig_fn_ty(ct, true)).as_str());
        out.append("    self: ?*anyopaque,\n    drop: ?*const fn (?*anyopaque) callconv(.c) void,\n};\n");
        var ps: std::vec<u32> = {};
        val r = this.fn_parts(ct, &ps);
        var ret = S("void");
        if (r != VOID) {
            ret = this.zig_cb_ty(r, 2);
        }
        out.append(fmt3("\n/// {}, Volt's: call(...) calls it; deinit() frees it\npub const fn{} = struct {{\n    c: closure{},\n", this.c.ty_name(ct), copy ki, copy ki).as_str());
        out.append(fmt4("\n    pub fn call(self: fn{}{}) {} {{\n        {}\n    }}\n", copy ki, this.zig_cb_params(&ps), move ret, this.zig_call_out("self.c.call", "self.c.self", &ps, r)).as_str());
        out.append(fmt("\n    pub fn deinit(self: fn{}) void {{\n        if (self.c.drop) |d| d(self.c.self);\n    }}\n}};\n", copy ki).as_str());
    }
    // a trait's object (its fns' table and the object; drop: null when it's lent) and table
    for (t&) in this.traits.items() {
        val tr = this.short(*t);
        out.append(fmt4("\n/// trait {}: a table of its fns and the object they're called on; drop frees the object\n/// (null: it's lent)\npub const {}_obj = extern struct {{\n    vt: *const {}_vt,\n{}", this.c.ty_name(*t), copy tr, copy tr, S("")).as_str());
        out.append("    self: ?*anyopaque,\n    drop: ?*const fn (?*anyopaque) callconv(.c) void,\n};\n");
        out.append(fmt2("\n/// trait {}'s fns, each taking the object first\npub const {}_vt = extern struct {{\n", this.c.ty_name(*t), copy tr).as_str());
        for (f&) in this.fns_of(*t).items() {
            var s = S("*const fn (?*anyopaque");
            for (p&) in f.params.items() {
                s.append(", ");
                s.append(this.zig_in(*p).as_str());
            }
            s.append(") callconv(.c) ");
            s.append(this.zig_out(f.ret).as_str());
            out.append(fmt2("    {}: {},\n", S(f.name), move s).as_str());
        }
        out.append("};\n");
    }
    for (k) in 0..this.traits.len {
        this.zig_trait(@cast<u32>(k), &out);
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
            args.append(fmt2("{}: {}", S(p.name), this.zig_in(p.ty)).as_str());
            match (this.shape_of(p.ty) ?? shape::VOID) {
                .CLOSURE(i) => { args.append(fmt(", {}_user: ?*anyopaque", S(p.name)).as_str()); },
                default => {},
            }
        }
        out.append(fmt3("    pub extern fn {}({}) {};\n", copy e.name, move args, this.zig_out(f.ret)).as_str());
    }
    out.append("};\n");
    for (s&) in this.handles.items() {
        val cls = this.local(this.c.si(*s).name);
        out.append(fmt4("\n/// export struct {}: owns a handle; deinit() frees it (one Volt lends, or one given to Volt,\n/// isn't yours to deinit)\npub const {} = struct {{\n    raw: *raw.{},\n\n    pub fn deinit(self: {}) void {{\n", S(this.c.si(*s).name), copy cls, copy cls, copy cls).as_str());
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
    return out;
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
    return out;
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
            return s;
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
        .TRAIT(i) => { return S("void"); }, // only C, C++, Rust and Zig take traits (bind.wide)
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
    return s;
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
    return out;
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
    return out;
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
            if (has_u32(&this.closures_out, i)) {
                // the struct one comes back in
                o.set("c_name", std::json::string(this.c_out(t, false).as_str()));
            }
        },
        .TRAIT(i) => {
            // a trait's object: lent (T&) or given (T)
            o.set("kind", std::json::string("object"));
            o.set("trait", std::json::string(this.short(this.trait_of(t)).as_str()));
            o.set("owned", std::json::boolean(!this.is_ref(t)));
        },
    }
    return o;
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
    for (t&) in this.traits.items() {
        var o = std::json::object();
        o.set("kind", std::json::string("trait"));
        o.set("name", std::json::string(this.short(*t).as_str()));
        o.set("c_name", std::json::string(this.c_named(this.short(*t).as_str(), false).as_str()));
        var vt = this.short(*t);
        vt.append("_vt");
        o.set("table", std::json::string(this.c_named(vt.as_str(), false).as_str()));
        var fs = std::json::array();
        for (f&) in this.fns_of(*t).items() {
            var fo = std::json::object();
            fo.set("name", std::json::string(f.name));
            var ps = std::json::array();
            for (p&) in f.params.items() {
                ps.add(this.json_ty(*p));
            }
            fo.set("params", move ps);
            fo.set("returns", this.json_ty(f.ret));
            fs.add(move fo);
        }
        o.set("fns", move fs);
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
    return text;
}

// ---------- Python type stubs ----------

// a type as the Python wrappers take it (incoming) or give it back
attach fn pyi_ty(this: bind&, t: u32, incoming: bool) -> std::string {
    val h = this.lent_handle(t);
    if (h) {
        return this.local(this.c.si(h).name);
    }
    match (this.shape_of(t) ?? shape::VOID) {
        .VOID => { return S("None"); },
        .BOOL => { return S("bool"); },
        .INT(k) => { return S("int"); },
        .FLOAT(b) => { return S("float"); },
        .CSTR => {
            if (incoming) {
                return S("str | bytes | None");
            }
            return S("str | None");
        },
        .STR => {
            if (incoming) {
                return S("str | bytes");
            }
            return S("str");
        },
        .TEXT(x) => { return S("str"); },
        .ENUM(e) => { return S("int"); },
        .CODE => { return S("int"); },
        .STRUCT(s) => { return this.local(this.c.si(s).name); },
        .PTR(x) => {
            if (x != VOID) {
                match (this.shape_of(x) ?? shape::VOID) {
                    .STRUCT(s) => { return this.local(this.c.si(s).name); },
                    default => {},
                }
            }
            return S("Any");
        },
        .ARRAY(elem, n) => { return S("Any"); },
        .SLICE(x) => {
            if (incoming) {
                return fmt("Sequence[{}]", this.pyi_ty(x, true));
            }
            return fmt("list[{}]", this.pyi_ty(x, false));
        },
        .OPT(x) => { return fmt("{} | None", this.pyi_ty(x, incoming)); },
        .HANDLE(s) => { return this.local(this.c.si(s).name); },
        .RESULT(e, x) => { return this.pyi_ty(x, incoming); },
        .FN(i) => { return S("Any"); },
        .CLOSURE(i) => {
            match (*this.c.t.get(t)) {
                .FN_VAL(ps&, r) => {
                    var s = S("Callable[[");
                    for (k) in 0..ps.len {
                        if (k > 0) {
                            s.append(", ");
                        }
                        s.append(this.pyi_ty(*ps.at(k), false).as_str());
                    }
                    s.append("], ");
                    s.append(this.pyi_ty(r, true).as_str());
                    s.push(']');
                    return s;
                },
                default => { return S("Callable[..., Any]"); },
            }
        },
        .TRAIT(i) => { return S("void"); }, // only C, C++, Rust and Zig take traits (bind.wide)
    }
}

// "name: T, ..." for f's parameters from first on
attach fn pyi_params(this: bind&, f: u32, first: usize) -> std::string {
    val info = this.c.fi(f);
    var ps: std::string = {};
    for (k) in first..info.params.len {
        if (ps.len() > 0) {
            ps.append(", ");
        }
        ps.append(fmt2("{}: {}", S(info.params.at(k).name), this.pyi_ty(info.params.at(k).ty, true)).as_str());
    }
    return ps;
}

// the doc comment above f as a docstring line, or "..."
attach fn pyi_body(this: bind&, f: u32) -> std::string {
    val sp = this.c.dl(this.c.fi(f).decl).item.span;
    val d = doc_above(this.c.files.at(sp.file).text, @cast<usize>(sp.lo));
    if (d.len() == 0) {
        return S("...");
    }
    var q: std::string = {};
    for (c) in d.as_str() {
        if (c == '"' || c == '\\') {
            q.push('\\');
        }
        q.push(c);
    }
    return fmt("\"\"\"{}\"\"\"", move q);
}

attach fn pyi_text(this: bind&) -> std::string {
    val ents = this.entries();
    var out = fmt("# {}: generated by voltc bindings; type stubs for the Python module (voltc bindings\n", S(this.pkg));
    out.append("# --lang python). Errors a Volt function returns are raised: a class per error set, all\n# deriving from Error.\nfrom typing import Any, Callable, Sequence\n");
    for (s&) in this.structs.items() {
        val info = this.c.si(*s);
        out.append(fmt("\n\nclass {}:\n", this.local(info.name)).as_str());
        var ps: std::string = {};
        for (f&) in info.fields.items() {
            out.append(fmt2("    {}: {}\n", S(f.name), this.pyi_ty(f.ty, false)).as_str());
            ps.append(fmt2(", {}: {} = ...", S(f.name), this.pyi_ty(f.ty, true)).as_str());
        }
        out.append(fmt("\n    def __init__(self{}) -> None: ...\n", move ps).as_str());
    }
    for (e&) in this.enums.items() {
        val info = this.c.ei(*e);
        out.append(fmt("\n\nclass {}:\n", this.local(info.name)).as_str());
        for (i) in 0..info.names.len {
            out.append(fmt("    {}: int\n", S(*info.names.at(i))).as_str());
        }
    }
    if (this.codes.len > 0) {
        out.append("\n\nclass Error(Exception):\n    \"\"\"an error a Volt function returned\"\"\"\n\n    code: int\n    name: str\n\n    def __init__(self, code: int) -> None: ...\n");
    }
    for (et&) in this.codes.items() {
        match (*this.c.t.get(*et)) {
            .ENUM(e) => {
                val info = this.c.ei(e);
                out.append(fmt("\n\nclass {}(Error):\n", this.local(info.name)).as_str());
                for (i) in 0..info.names.len {
                    out.append(fmt("    {}: int\n", S(*info.names.at(i))).as_str());
                }
            },
            default => {},
        }
    }
    for (s&) in this.handles.items() {
        val cls = this.local(this.c.si(*s).name);
        out.append(fmt2("\n\nclass {}:\n    \"\"\"export struct {}: close() (or a with block) frees it\"\"\"\n", copy cls, S(this.c.si(*s).name)).as_str());
        out.append(fmt("\n    def close(self) -> None: ...\n    def __enter__(self) -> {}: ...\n    def __exit__(self, *exc: object) -> None: ...\n", copy cls).as_str());
        for (e&) in ents.items() {
            if (e.free_of != null) {
                continue;
            }
            val m = this.member_of(e.f, *s) ?? continue;
            val info = this.c.fi(e.f);
            if (this.node_is_method(e.f, *s)) {
                var ps = S("self");
                val rest = this.pyi_params(e.f, 1);
                if (rest.len() > 0) {
                    ps.append(", ");
                    ps.append(rest.as_str());
                }
                out.append(fmt4("    def {}({}) -> {}: {}\n", S(m), move ps, this.pyi_ty(info.ret, false), this.pyi_body(e.f)).as_str());
            } else if (m == "new") {
                var ps = S("self");
                val rest = this.pyi_params(e.f, 0);
                if (rest.len() > 0) {
                    ps.append(", ");
                    ps.append(rest.as_str());
                }
                out.append(fmt2("    def __init__({}) -> None: {}\n", move ps, this.pyi_body(e.f)).as_str());
            } else {
                out.append(fmt4("    @staticmethod\n    def {}({}) -> {}: {}\n", S(m), this.pyi_params(e.f, 0), this.pyi_ty(info.ret, false), this.pyi_body(e.f)).as_str());
            }
        }
    }
    out.append("\n");
    for (e&) in ents.items() {
        if (e.free_of != null || this.class_of(e.f) != null) {
            continue;
        }
        val info = this.c.fi(e.f);
        out.append(fmt4("\ndef {}({}) -> {}: {}\n", S(info.c_name), this.pyi_params(e.f, 0), this.pyi_ty(info.ret, false), this.pyi_body(e.f)).as_str());
    }
    return out;
}

// ---------- C# ----------

fn cs_keyword(s: str) -> bool {
    val words: str[] = { "abstract", "as", "base", "bool", "break", "byte", "case", "catch", "char", "checked", "class", "const", "continue", "decimal", "default", "delegate", "do", "double", "else", "enum", "event", "explicit", "extern", "false", "finally", "fixed", "float", "for", "foreach", "goto", "if", "implicit", "in", "int", "interface", "internal", "is", "lock", "long", "namespace", "new", "null", "object", "operator", "out", "override", "params", "private", "protected", "public", "readonly", "ref", "return", "sbyte", "sealed", "short", "sizeof", "stackalloc", "static", "string", "struct", "switch", "this", "throw", "true", "try", "typeof", "uint", "ulong", "unchecked", "unsafe", "ushort", "using", "virtual", "void", "volatile", "while" };
    for (w) in words {
        if (w == s) {
            return true;
        }
    }
    return false;
}

fn cs_ident(s: str) -> std::string {
    if (cs_keyword(s)) {
        return fmt("@{}", S(s));
    }
    return S(s);
}

fn cs_int(k: int_ty) -> str {
    if (k == int_ty::I8) {
        return "sbyte";
    }
    if (k == int_ty::U8) {
        return "byte";
    }
    if (k == int_ty::I16) {
        return "short";
    }
    if (k == int_ty::U16) {
        return "ushort";
    }
    if (k == int_ty::I32) {
        return "int";
    }
    if (k == int_ty::U32) {
        return "uint";
    }
    if (k == int_ty::I64) {
        return "long";
    }
    if (k == int_ty::U64) {
        return "ulong";
    }
    if (k == int_ty::ISIZE) {
        return "nint";
    }
    return "nuint";
}

// a type as the C functions (class Native) see it: blittable, bool as a byte
attach fn cs_raw(this: bind&, t: u32) -> std::string {
    match (this.shape_of(t) ?? shape::VOID) {
        .VOID => { return S("void"); },
        .BOOL => { return S("byte"); },
        .INT(k) => { return S(cs_int(k)); },
        .FLOAT(b) => {
            if (b == 32) {
                return S("float");
            }
            return S("double");
        },
        .CSTR => { return S("byte*"); },
        .STR => { return S("VoltStr"); },
        .TEXT(x) => { return S("VoltText"); },
        .PTR(x) => {
            if (x == VOID) {
                return S("void*");
            }
            match (this.shape_of(x) ?? shape::VOID) {
                .HANDLE(s) => { return S("IntPtr"); },
                default => {},
            }
            return fmt("{}*", this.cs_raw(x));
        },
        .HANDLE(s) => { return S("IntPtr"); },
        .STRUCT(s) => { return this.local(this.c.si(s).name); },
        .ENUM(e) => { return this.local(this.c.ei(e).name); },
        .CODE => { return S("uint"); },
        .RESULT(e, x) => { return this.result_name(t); },
        .ARRAY(elem, n) => { return S("IntPtr"); },
        .SLICE(x) => { return this.made_name("slice", x, true); },
        .OPT(x) => { return this.made_name("opt", x, true); },
        .FN(i) => { return S("IntPtr"); },
        .CLOSURE(i) => { return this.cs_fnptr(t); },
        .TRAIT(i) => { return S("void"); }, // only C, C++, Rust and Zig take traits (bind.wide)
    }
}

// a closure parameter's C function: delegate* unmanaged<IntPtr, A..., R>
attach fn cs_fnptr(this: bind&, t: u32) -> std::string {
    var s = S("delegate* unmanaged<IntPtr");
    match (*this.c.t.get(t)) {
        .FN_VAL(ps&, r) => {
            for (p&) in ps.items() {
                s.append(", ");
                s.append(this.cs_raw(*p).as_str());
            }
            s.append(", ");
            s.append(this.cs_raw(r).as_str());
        },
        default => {},
    }
    s.push('>');
    return s;
}

// a type as the C# API shows it
attach fn cs_ty(this: bind&, t: u32) -> std::string {
    val h = this.lent_handle(t);
    if (h) {
        return this.local(this.c.si(h).name);
    }
    match (this.shape_of(t) ?? shape::VOID) {
        .BOOL => { return S("bool"); },
        .CSTR => { return S("string?"); },
        .STR => { return S("string"); },
        .TEXT(x) => { return S("string"); },
        .PTR(x) => {
            if (x != VOID) {
                match (this.shape_of(x) ?? shape::VOID) {
                    .STRUCT(s) => { return fmt("ref {}", this.local(this.c.si(s).name)); },
                    default => {},
                }
            }
            return this.cs_raw(t);
        },
        .HANDLE(s) => { return this.local(this.c.si(s).name); },
        .SLICE(x) => { return fmt("Span<{}>", this.cs_raw(x)); },
        .OPT(x) => { return fmt("{}?", this.cs_raw(x)); },
        .RESULT(e, x) => { return this.cs_ty(x); },
        .CLOSURE(i) => {
            match (*this.c.t.get(t)) {
                .FN_VAL(ps&, r) => {
                    var args: std::string = {};
                    for (p&) in ps.items() {
                        if (args.len() > 0) {
                            args.append(", ");
                        }
                        args.append(this.cs_ty(*p).as_str());
                    }
                    if (r == VOID) {
                        if (ps.len == 0) {
                            return S("Action");
                        }
                        return fmt("Action<{}>", move args);
                    }
                    if (args.len() > 0) {
                        args.append(", ");
                    }
                    args.append(this.cs_ty(r).as_str());
                    return fmt("Func<{}>", move args);
                },
                default => { return S("Delegate"); },
            }
        },
        default => { return this.cs_raw(t); },
    }
}

// one parameter of a wrapper: its C# declaration, what it passes, and the statements that open
// (fixed blocks, buffers) and close (copy-back, rethrow) around the call
struct cs_arg {
    decl: std::string = {};
    pass: std::string = {};
    open: std::string = {};
    close: std::string = {};
}

attach fn cs_arg_of(this: bind&, t: u32, name0: str, a: cs_arg&) -> void {
    val nm = cs_ident(name0);
    val name = nm.as_str();
    val h = this.lent_handle(t);
    if (h) {
        a.decl = fmt2("{} {}", this.local(this.c.si(h).name), S(name));
        a.pass = fmt("{}.h.DangerousGetHandle()", S(name));
        // the handle stays alive (and can't be freed) for the call
        a.open = fmt2("bool {}_ref = false;\n{}.h.DangerousAddRef(ref ", S(name0), S(name));
        a.open.append(fmt("{}_ref);\ntry {\n", S(name0)).as_str());
        a.close = fmt2("}\nfinally {{\n    if ({}_ref) {{\n        {}.h.DangerousRelease();\n    }}\n}}\n", S(name0), S(name));
        return;
    }
    match (this.shape_of(t) ?? shape::VOID) {
        .BOOL => {
            a.decl = fmt("bool {}", S(name));
            a.pass = fmt("(byte)({} ? 1 : 0)", S(name));
        },
        .STR => {
            a.decl = fmt("string {}", S(name));
            a.open = fmt3("byte[] {}_b = Encoding.UTF8.GetBytes({});\nfixed (byte* {}_p = ", S(name0), S(name), S(name0));
            a.open.append(fmt2("{}_b) {{\n", S(name0), S("")).as_str());
            a.pass = fmt2("new VoltStr {{ ptr = {}_p, len = (nuint){}_b.Length }}", S(name0), S(name0));
            a.close = S("}\n");
        },
        .CSTR => {
            a.decl = fmt("string? {}", S(name));
            a.open = fmt3("byte[]? {}_b = {} == null ? null : Encoding.UTF8.GetBytes({} + \"\\0\");\n", S(name0), S(name), S(name));
            a.open.append(fmt2("fixed (byte* {}_p = {}_b) {{\n", S(name0), S(name0)).as_str());
            a.pass = fmt("{}_p", S(name0));
            a.close = S("}\n");
        },
        .PTR(x) => {
            if (x != VOID) {
                match (this.shape_of(x) ?? shape::VOID) {
                    .STRUCT(s) => {
                        a.decl = fmt2("ref {} {}", this.local(this.c.si(s).name), S(name));
                        a.open = fmt3("fixed ({}* {}_p = &{}) {{\n", this.local(this.c.si(s).name), S(name0), S(name));
                        a.pass = fmt("{}_p", S(name0));
                        a.close = S("}\n");
                        return;
                    },
                    default => {},
                }
            }
            a.decl = fmt2("{} {}", this.cs_raw(t), S(name));
            a.pass = S(name);
        },
        .SLICE(x) => {
            a.decl = fmt2("Span<{}> {}", this.cs_raw(x), S(name));
            a.open = fmt3("fixed ({}* {}_p = {}) {{\n", this.cs_raw(x), S(name0), S(name));
            a.pass = fmt3("new {} {{ ptr = {}_p, len = (nuint){}.Length }}", this.made_name("slice", x, true), S(name0), S(name));
            a.close = S("}\n");
        },
        .OPT(x) => {
            a.decl = fmt2("{}? {}", this.cs_raw(x), S(name));
            a.pass = fmt3("new {} {{ value = {}.GetValueOrDefault(), has = (byte)({}.HasValue ? 1 : 0) }}", this.made_name("opt", x, true), S(name), S(name));
        },
        .CLOSURE(i) => {
            a.decl = fmt2("{} {}", this.cs_ty(t), S(name));
            // the C function finds the delegate through a GCHandle; an exception it throws comes back
            // out of this call
            a.open = fmt3("var {}_s = new Callback({});\nGCHandle {}_g = GCHandle.Alloc(", S(name0), S(name), S(name0));
            a.open.append(fmt2("{}_s);\ntry {{\n", S(name0), S("")).as_str());
            a.pass = fmt3("&Callbacks.cb{}, GCHandle.ToIntPtr({}_g)", unum(@cast<u64>(i)), S(name0), S(""));
            a.close = fmt3("}}\nfinally {{\n    {}_g.Free();\n}}\n{}_s.Rethrow();\n", S(name0), S(name0), S(""));
        },
        default => {
            a.decl = fmt2("{} {}", this.cs_ty(t), S(name));
            a.pass = S(name);
        },
    }
}

// the C# value of C result r (of type t)
attach fn cs_value(this: bind&, t: u32, r: str) -> std::string {
    match (this.shape_of(t) ?? shape::VOID) {
        .BOOL => { return fmt("{} != 0", S(r)); },
        .STR => { return fmt("VoltStr.Text({})", S(r)); },
        .CSTR => { return fmt("Marshal.PtrToStringUTF8((IntPtr){})", S(r)); },
        .TEXT(x) => { return fmt("VoltText.Take({})", S(r)); },
        .HANDLE(s) => { return fmt3("new {}(new {}Handle({}))", this.local(this.c.si(s).name), this.local(this.c.si(s).name), S(r)); },
        .OPT(x) => { return fmt3("{}.has != 0 ? {}.value : null", S(r), S(r), S("")); },
        default => { return S(r); },
    }
}

// a wrapper's body: the call inside its parameters' blocks, the error check, the result
attach fn cs_body(this: bind&, f: u32, args: std::vec<cs_arg>&, ctor: bool) -> std::string {
    val info = this.c.fi(f);
    var passes: std::string = {};
    var open: std::string = {};
    var close: std::string = {};
    for (a&) in args.items() {
        if (passes.len() > 0) {
            passes.append(", ");
        }
        passes.append(a.pass.as_str());
        open.append(a.open.as_str());
    }
    var k = args.len;
    while (k > 0) {
        k -= 1;
        close.append(args.at(k).close.as_str());
    }
    var call = fmt2("Native.{}({})", S(info.c_name), move passes);
    var body: std::string = {};
    var ret_decl: std::string = {};
    if (info.ret == VOID) {
        body = fmt("{};\n", move call);
    } else {
        ret_decl = fmt("{} result;\n", this.cs_ty(info.ret));
        val made = this.makes(f);
        if (ctor && made != null) {
            ret_decl = fmt("{}Handle result;\n", this.local(this.c.si(made ?? 0).name));
        }
        match (this.shape_of(info.ret) ?? shape::VOID) {
            .RESULT(e, x) => {
                body = fmt("var r = {};\nif (r.error != 0) {\n    throw VoltException.For(r.error);\n}\n", move call);
                if (x == VOID) {
                    ret_decl = {};
                } else if (ctor && made != null) {
                    body.append(fmt2("result = new {}Handle({});\n", this.local(this.c.si(made ?? 0).name), S("r.value")).as_str());
                } else {
                    body.append(fmt("result = {};\n", this.cs_value(x, "r.value")).as_str());
                }
            },
            default => {
                if (ctor && made != null) {
                    body = fmt2("var r = {};\nresult = new {}Handle(r);\n", move call, this.local(this.c.si(made ?? 0).name));
                } else {
                    body = fmt2("var r = {};\nresult = {};\n", move call, this.cs_value(info.ret, "r"));
                }
            },
        }
    }
    var out = move ret_decl;
    out.append(open.as_str());
    out.append(body.as_str());
    out.append(close.as_str());
    if (info.ret != VOID) {
        match (this.shape_of(info.ret) ?? shape::VOID) {
            .RESULT(e, x) => {
                if (x != VOID) {
                    out.append("return result;\n");
                }
            },
            default => { out.append("return result;\n"); },
        }
    }
    return out;
}

// lines of s, indented by n spaces
fn indent_n(s: str, n: usize) -> std::string {
    var out: std::string = {};
    var start = true;
    for (c) in s {
        if (start && c != '\n') {
            for (i) in 0..n {
                out.push(' ');
            }
        }
        out.push(c);
        start = c == '\n';
    }
    return out;
}

attach fn cs_args(this: bind&, f: u32, first: usize) -> std::vec<cs_arg> {
    val info = this.c.fi(f);
    var out: std::vec<cs_arg> = {};
    for (k) in first..info.params.len {
        var a: cs_arg = {};
        this.cs_arg_of(info.params.at(k).ty, info.params.at(k).name, &a);
        put(&out, move a);
    }
    return out;
}

fn cs_decls(args: std::vec<cs_arg>&) -> std::string {
    var s: std::string = {};
    for (a&) in args.items() {
        if (s.len() > 0) {
            s.append(", ");
        }
        s.append(a.decl.as_str());
    }
    return s;
}

attach fn cs_doc(this: bind&, f: u32, ind: usize) -> std::string {
    val sp = this.c.dl(this.c.fi(f).decl).item.span;
    val d = doc_above(this.c.files.at(sp.file).text, @cast<usize>(sp.lo));
    if (d.len() == 0) {
        return {};
    }
    var q: std::string = {};
    for (c) in d.as_str() {
        if (c == '<') {
            q.append("&lt;");
        } else if (c == '&') {
            q.append("&amp;");
        } else {
            q.push(c);
        }
    }
    return indent_n(fmt("/// <summary>{}</summary>\n", move q).as_str(), ind);
}

attach fn cs_text(this: bind&) -> std::string {
    val ents = this.entries();
    var out = fmt("// {}: generated by voltc bindings; the Volt package for C# (.NET 7 or later). It calls\n", S(this.pkg));
    out.append(fmt2("// lib{}.so (or {}.dll, lib", S(this.pkg), S(this.pkg)).as_str());
    out.append(fmt("{}.dylib) through LibraryImport; build with AllowUnsafeBlocks. Errors are thrown as\n// VoltException, one subclass per error set.\n", S(this.pkg)).as_str());
    out.append("#nullable enable\n#pragma warning disable CS8981 // the type names are Volt's (lower case)\nusing System;\nusing System.Runtime.CompilerServices;\nusing System.Runtime.InteropServices;\nusing System.Text;\n\n");
    out.append(fmt("namespace {};\n", S(this.pkg)).as_str());
    out.append("\n/// <summary>a Volt str: UTF-8 bytes and a length</summary>\n[StructLayout(LayoutKind.Sequential)]\npublic unsafe struct VoltStr\n{\n    public byte* ptr;\n    public nuint len;\n\n    public static string Text(VoltStr s) => Encoding.UTF8.GetString(s.ptr, (int)s.len);\n}\n");
    if (this.texts.len > 0) {
        out.append("\n/// <summary>owned text a Volt function gave out (the wrappers copy it into a string and free it)</summary>\n[StructLayout(LayoutKind.Sequential)]\npublic unsafe struct VoltText\n{\n    public byte* ptr;\n    public nuint len;\n    public IntPtr owner;\n    public delegate* unmanaged<IntPtr, void> drop;\n\n    public static string Take(VoltText t)\n    {\n        string s = Encoding.UTF8.GetString(t.ptr, (int)t.len);\n        if (t.drop != null)\n        {\n            t.drop(t.owner);\n        }\n        return s;\n    }\n}\n");
    }
    for (x&) in this.slices.items() {
        out.append(fmt2("\n/// <summary>a Volt slice: elements and how many</summary>\n[StructLayout(LayoutKind.Sequential)]\npublic unsafe struct {}\n{{\n    public {}* ptr;\n    public nuint len;\n}}\n", this.made_name("slice", *x, true), this.cs_raw(*x)).as_str());
    }
    for (x&) in this.opts.items() {
        out.append(fmt2("\n/// <summary>a Volt optional: has (0 or 1) says whether value is there</summary>\n[StructLayout(LayoutKind.Sequential)]\npublic struct {}\n{{\n    public {} value;\n    public byte has;\n}}\n", this.made_name("opt", *x, true), this.cs_raw(*x)).as_str());
    }
    // errors: one exception class per error set, holding its codes too
    out.append("\n/// <summary>an error a Volt function returned: its code and name</summary>\npublic class VoltException : Exception\n{\n    public uint Code { get; }\n    public string Name { get; }\n\n    public VoltException(uint code, string name) : base(name)\n    {\n        Code = code;\n        Name = name;\n    }\n\n    internal static VoltException For(uint code)\n    {\n        switch (code)\n        {\n");
    for (c&) in this.all_codes().items() {
        out.append(fmt4("            case {}u: return new {}(code, \"{}\");\n", num(c.code), copy c.set, S(c.name), S("")).as_str());
    }
    out.append("            default: return new VoltException(code, \"error\");\n        }\n    }\n}\n");
    for (et&) in this.codes.items() {
        match (*this.c.t.get(*et)) {
            .ENUM(e) => {
                val info = this.c.ei(e);
                val n = this.local(info.name);
                out.append(fmt3("\n/// <summary>error set {}: thrown for its errors; its codes</summary>\npublic class {} : VoltException\n{{\n    public {}(uint code, string name) : base(code, name) {{ }}\n\n", S(info.name), copy n, copy n).as_str());
                for (i) in 0..info.names.len {
                    out.append(fmt2("    public const uint {} = {}u;\n", S(*info.names.at(i)), num(*info.values.at(i))).as_str());
                }
                out.append("}\n");
            },
            default => {},
        }
    }
    for (e&) in this.enums.items() {
        val info = this.c.ei(*e);
        out.append(fmt2("\npublic enum {} : {}\n{{\n", this.local(info.name), S(cs_int(info.tag))).as_str());
        for (i) in 0..info.names.len {
            out.append(fmt2("    {} = {},\n", S(*info.names.at(i)), num(*info.values.at(i))).as_str());
        }
        out.append("}\n");
    }
    for (s&) in this.structs.items() {
        val info = this.c.si(*s);
        out.append(fmt("\n[StructLayout(LayoutKind.Sequential)]\npublic unsafe struct {}\n{{\n", this.local(info.name)).as_str());
        for (f&) in info.fields.items() {
            match (*this.c.t.get(f.ty)) {
                .ARRAY(elem, n) => { out.append(fmt3("    public fixed {} {}[{}];\n", this.cs_raw(elem), cs_ident(f.name), unum(n)).as_str()); },
                default => { out.append(fmt2("    public {} {};\n", this.cs_raw(f.ty), cs_ident(f.name)).as_str()); },
            }
        }
        out.append("}\n");
    }
    for (rt&) in this.results.items() {
        match (*this.c.t.get(*rt)) {
            .ERR_UNION(e, x) => {
                out.append(fmt2("\n/// <summary>{}: error is 0, or the error's code</summary>\n[StructLayout(LayoutKind.Sequential)]\npublic unsafe struct {}\n{{\n    public uint error;\n", this.c.ty_name(*rt), this.result_name(*rt)).as_str());
                if (x != VOID) {
                    out.append(fmt("    public {} value;\n", this.cs_raw(x)).as_str());
                }
                out.append("}\n");
            },
            default => {},
        }
    }
    // the C functions
    out.append(fmt("\n/// <summary>the C functions (the classes below are easier to use)</summary>\npublic static unsafe partial class Native\n{{\n    public const string Lib = \"{}\";\n", S(this.pkg)).as_str());
    for (e&) in ents.items() {
        var ps: std::string = {};
        var ret = S("void");
        val s = e.free_of;
        if (s) {
            ps = S("IntPtr it");
        } else {
            val f = this.c.fi(e.f);
            ret = this.cs_raw(f.ret);
            for (p&) in f.params.items() {
                if (ps.len() > 0) {
                    ps.append(", ");
                }
                ps.append(fmt2("{} {}", this.cs_raw(p.ty), cs_ident(p.name)).as_str());
                match (this.shape_of(p.ty) ?? shape::VOID) {
                    .CLOSURE(i) => { ps.append(fmt(", IntPtr {}_user", S(p.name)).as_str()); },
                    default => {},
                }
            }
        }
        out.append(fmt4("\n    [LibraryImport(Lib, EntryPoint = \"{}\")]\n    public static partial {} {}({});\n", copy e.name, move ret, copy e.name, move ps).as_str());
    }
    out.append("}\n");
    // callbacks: the C functions a closure parameter calls, which call the delegate
    if (this.closures.len > 0) {
        out.append("\n// a delegate passed for a callback, and what it threw (rethrown after the call)\ninternal sealed class Callback\n{\n    public readonly Delegate F;\n    public Exception? Error;\n\n    public Callback(Delegate f) => F = f;\n\n    public void Rethrow()\n    {\n        if (Error != null)\n        {\n            System.Runtime.ExceptionServices.ExceptionDispatchInfo.Capture(Error).Throw();\n        }\n    }\n}\n\ninternal static unsafe class Callbacks\n{");
        for (i) in 0..this.closures.len {
            val ct = *this.closures.at(i);
            match (*this.c.t.get(ct)) {
                .FN_VAL(ps&, r) => {
                    var params = S("IntPtr user");
                    var args: std::string = {};
                    for (k) in 0..ps.len {
                        params.append(fmt2(", {} a{}", this.cs_raw(*ps.at(k)), unum(@cast<u64>(k))).as_str());
                        if (k > 0) {
                            args.append(", ");
                        }
                        args.append(this.cs_value(*ps.at(k), fmt("a{}", unum(@cast<u64>(k))).as_str()).as_str());
                    }
                    out.append(fmt3("\n    [UnmanagedCallersOnly]\n    public static {} cb{}({})\n    {{\n        var c = (Callback)GCHandle.FromIntPtr(user).Target!;\n        try\n        {{\n", this.cs_raw(r), unum(@cast<u64>(i)), move params).as_str());
                    val call = fmt3("(({})c.F)({})", this.cs_ty(ct), move args, S(""));
                    if (r == VOID) {
                        out.append(fmt("            {};\n", move call).as_str());
                    } else {
                        match (this.shape_of(r) ?? shape::VOID) {
                            .BOOL => { out.append(fmt("            return (byte)({} ? 1 : 0);\n", move call).as_str()); },
                            default => { out.append(fmt("            return {};\n", move call).as_str()); },
                        }
                    }
                    out.append("        }\n        catch (Exception e)\n        {\n            c.Error ??= e;\n");
                    if (r != VOID) {
                        out.append("            return default;\n");
                    }
                    out.append("        }\n    }\n");
                },
                default => {},
            }
        }
        out.append("}\n");
    }
    // a class per export struct, over a SafeHandle
    for (s&) in this.handles.items() {
        val cls = this.local(this.c.si(*s).name);
        out.append(fmt4("\n/// <summary>owns a handle to export struct {}; Dispose (or a using block, or the finalizer) frees it</summary>\npublic sealed class {}Handle : SafeHandle\n{{\n    public {}Handle() : base(IntPtr.Zero, true) {{ }}\n    public {}Handle(IntPtr h) : base(IntPtr.Zero, true) => SetHandle(h);\n", S(this.c.si(*s).name), copy cls, copy cls, copy cls).as_str());
        out.append(fmt("    public override bool IsInvalid => handle == IntPtr.Zero;\n\n    protected override bool ReleaseHandle()\n    {\n        Native.{}(handle);\n        return true;\n    }\n}\n", this.free_name(*s)).as_str());
        out.append(fmt3("\n/// <summary>export struct {}</summary>\npublic sealed unsafe class {} : IDisposable\n{{\n    internal readonly {}Handle h;\n\n", S(this.c.si(*s).name), copy cls, copy cls).as_str());
        out.append(fmt2("    public {}({}Handle h) => this.h = h;\n\n    public void Dispose() => h.Dispose();\n", copy cls, copy cls).as_str());
        for (e&) in ents.items() {
            if (e.free_of != null) {
                continue;
            }
            val m = this.member_of(e.f, *s) ?? continue;
            val info = this.c.fi(e.f);
            out.append("\n");
            out.append(this.cs_doc(e.f, 4).as_str());
            if (this.node_is_method(e.f, *s)) {
                var args = this.cs_args(e.f, 1);
                // this instance's handle stays alive (and can't be freed) for the call
                var self_arg: cs_arg = { decl: {}, pass: S("h.DangerousGetHandle()"), open: S("bool self_ref = false;\nh.DangerousAddRef(ref self_ref);\ntry {\n"), close: S("}\nfinally {\n    if (self_ref) {\n        h.DangerousRelease();\n    }\n}\n") };
                var all: std::vec<cs_arg> = {};
                put(&all, move self_arg);
                for (a&) in args.items() {
                    put(&all, copy *a);
                }
                out.append(fmt3("    public {} {}({})\n    {{\n", this.cs_ty(info.ret), cs_ident(m), cs_decls(&args)).as_str());
                out.append(indent_n(this.cs_body(e.f, &all, false).as_str(), 8).as_str());
                out.append("    }\n");
            } else if (m == "new") {
                var args = this.cs_args(e.f, 0);
                out.append(fmt2("    public {}({}) : this(Make(", copy cls, cs_decls(&args)).as_str());
                var names: std::string = {};
                for (k) in 0..info.params.len {
                    if (k > 0) {
                        names.append(", ");
                    }
                    names.append(cs_ident(info.params.at(k).name).as_str());
                }
                out.append(fmt2("{})) {{ }}\n\n    private static {}Handle Make(", move names, copy cls).as_str());
                out.append(fmt("{})\n    {\n", cs_decls(&args)).as_str());
                var body = this.cs_body(e.f, &args, true);
                out.append(indent_n(body.as_str(), 8).as_str());
                out.append("    }\n");
            } else {
                var args = this.cs_args(e.f, 0);
                out.append(fmt3("    public static {} {}({})\n    {{\n", this.cs_ty(info.ret), cs_ident(m), cs_decls(&args)).as_str());
                out.append(indent_n(this.cs_body(e.f, &args, false).as_str(), 8).as_str());
                out.append("    }\n");
            }
        }
        out.append("}\n");
    }
    // the functions
    out.append(fmt("\n/// <summary>the package's functions</summary>\npublic static unsafe class Api\n{{\n", S("")).as_str());
    var firstfn = true;
    for (e&) in ents.items() {
        if (e.free_of != null || this.class_of(e.f) != null) {
            continue;
        }
        val info = this.c.fi(e.f);
        var args = this.cs_args(e.f, 0);
        if (!firstfn) {
            out.append("\n");
        }
        firstfn = false;
        out.append(this.cs_doc(e.f, 4).as_str());
        out.append(fmt3("    public static {} {}({})\n    {{\n", this.cs_ty(info.ret), cs_ident(info.c_name), cs_decls(&args)).as_str());
        out.append(indent_n(this.cs_body(e.f, &args, false).as_str(), 8).as_str());
        out.append("    }\n");
    }
    out.append("}\n");
    return out;
}

// ---------- Java (the FFM API, Java 22+) ----------

// size and alignment of a type's C form (what Java's layouts need spelled out, padding and all)
struct c_size {
    size: u64;
    align: u64;
}

attach fn csize(this: bind&, t: u32) -> c_size {
    match (this.shape_of(t) ?? shape::VOID) {
        .VOID => { return { size: 0, align: 1 }; },
        .BOOL => { return { size: 1, align: 1 }; },
        .INT(k) => {
            val b = @cast<u64>(k.bits()) / 8;
            return { size: b, align: b };
        },
        .FLOAT(b) => {
            val n = @cast<u64>(b) / 8;
            return { size: n, align: n };
        },
        .ENUM(e) => {
            val b = @cast<u64>(this.c.ei(e).tag.bits()) / 8;
            return { size: b, align: b };
        },
        .CODE => { return { size: 4, align: 4 }; },
        .STR => { return { size: 16, align: 8 }; },
        .SLICE(x) => { return { size: 16, align: 8 }; },
        .TEXT(x) => { return { size: 32, align: 8 }; },
        .ARRAY(elem, n) => {
            val e = this.csize(elem);
            return { size: e.size * n, align: e.align };
        },
        .STRUCT(s) => { return this.struct_size(s); },
        .OPT(x) => {
            val v = this.csize(x);
            return { size: align_to(v.size + 1, v.align), align: v.align };
        },
        .RESULT(e, x) => {
            if (x == VOID) {
                return { size: 4, align: 4 };
            }
            val v = this.csize(x);
            var a = v.align;
            if (a < 4) {
                a = 4;
            }
            return { size: align_to(align_to(4, v.align) + v.size, a), align: a };
        },
        default => { return { size: 8, align: 8 }; },
    }
}

fn align_to(n: u64, a: u64) -> u64 {
    if (a <= 1) {
        return n;
    }
    return (n + a - 1) / a * a;
}

attach fn struct_size(this: bind&, s: u32) -> c_size {
    var off: u64 = 0;
    var al: u64 = 1;
    for (f&) in this.c.si(s).fields.items() {
        val z = this.csize(f.ty);
        off = align_to(off, z.align) + z.size;
        if (z.align > al) {
            al = z.align;
        }
    }
    return { size: align_to(off, al), align: al };
}

// the ValueLayout a scalar crosses as
attach fn java_vl(this: bind&, t: u32) -> std::string {
    match (this.shape_of(t) ?? shape::VOID) {
        .BOOL => { return S("JAVA_BOOLEAN"); },
        .INT(k) => {
            val b = k.bits();
            if (b == 8) {
                return S("JAVA_BYTE");
            }
            if (b == 16) {
                return S("JAVA_SHORT");
            }
            if (b == 32) {
                return S("JAVA_INT");
            }
            return S("JAVA_LONG");
        },
        .FLOAT(b) => {
            if (b == 32) {
                return S("JAVA_FLOAT");
            }
            return S("JAVA_DOUBLE");
        },
        .ENUM(e) => {
            return this.java_vl(int_id(this.c.ei(e).tag));
        },
        .CODE => { return S("JAVA_INT"); },
        default => { return S("ADDRESS"); },
    }
}

// is t passed by value as a struct (a MemorySegment holding it)?
attach fn java_is_struct(this: bind&, t: u32) -> bool {
    match (this.shape_of(t) ?? shape::VOID) {
        .STRUCT(s) => { return true; },
        .STR => { return true; },
        .TEXT(x) => { return true; },
        .SLICE(x) => { return true; },
        .OPT(x) => { return true; },
        .RESULT(e, x) => { return true; },
        default => { return false; },
    }
}

// the MemoryLayout of a type (fields named, padding spelled out)
attach fn java_layout(this: bind&, t: u32) -> std::string {
    match (this.shape_of(t) ?? shape::VOID) {
        .STRUCT(s) => { return fmt("L_{}", this.local(this.c.si(s).name)); },
        .STR => { return S("L_STR"); },
        .TEXT(x) => { return S("L_TEXT"); },
        .SLICE(x) => { return S("L_SLICE"); },
        .ARRAY(elem, n) => { return fmt2("MemoryLayout.sequenceLayout({}, {})", unum(n), this.java_layout(elem)); },
        .OPT(x) => {
            val v = this.csize(x);
            val pad = this.csize(t).size - v.size - 1;
            var s = fmt2("MemoryLayout.structLayout({}.withName(\"value\"), JAVA_BOOLEAN.withName(\"has\"){}", this.java_layout(x), S(""));
            if (pad > 0) {
                s.append(fmt(", MemoryLayout.paddingLayout({})", unum(pad)).as_str());
            }
            s.push(')');
            return s;
        },
        .RESULT(e, x) => {
            if (x == VOID) {
                return S("MemoryLayout.structLayout(JAVA_INT.withName(\"error\"))");
            }
            val v = this.csize(x);
            val off = align_to(4, v.align);
            var s = S("MemoryLayout.structLayout(JAVA_INT.withName(\"error\")");
            if (off > 4) {
                s.append(fmt(", MemoryLayout.paddingLayout({})", unum(off - 4)).as_str());
            }
            s.append(fmt(", {}.withName(\"value\")", this.java_layout(x)).as_str());
            val tail = this.csize(t).size - off - v.size;
            if (tail > 0) {
                s.append(fmt(", MemoryLayout.paddingLayout({})", unum(tail)).as_str());
            }
            s.push(')');
            return s;
        },
        default => { return this.java_vl(t); },
    }
}

// a type as the Java API shows it
attach fn java_ty(this: bind&, t: u32, boxed: bool) -> std::string {
    val h = this.lent_handle(t);
    if (h) {
        return this.local(this.c.si(h).name);
    }
    match (this.shape_of(t) ?? shape::VOID) {
        .VOID => { return S("void"); },
        .BOOL => {
            if (boxed) {
                return S("Boolean");
            }
            return S("boolean");
        },
        .INT(k) => {
            val b = k.bits();
            if (b == 8) {
                if (boxed) {
                    return S("Byte");
                }
                return S("byte");
            }
            if (b == 16) {
                if (boxed) {
                    return S("Short");
                }
                return S("short");
            }
            if (b == 32) {
                if (boxed) {
                    return S("Integer");
                }
                return S("int");
            }
            if (boxed) {
                return S("Long");
            }
            return S("long");
        },
        .FLOAT(b) => {
            if (b == 32) {
                if (boxed) {
                    return S("Float");
                }
                return S("float");
            }
            if (boxed) {
                return S("Double");
            }
            return S("double");
        },
        .CSTR => { return S("String"); },
        .STR => { return S("String"); },
        .TEXT(x) => { return S("String"); },
        .ENUM(e) => { return this.local(this.c.ei(e).name); },
        .CODE => { return S("int"); },
        .STRUCT(s) => { return this.local(this.c.si(s).name); },
        .PTR(x) => {
            if (x != VOID) {
                match (this.shape_of(x) ?? shape::VOID) {
                    .STRUCT(s) => { return this.local(this.c.si(s).name); },
                    default => {},
                }
            }
            return S("MemorySegment");
        },
        .HANDLE(s) => { return this.local(this.c.si(s).name); },
        .SLICE(x) => { return fmt("{}[]", this.java_ty(x, false)); },
        .OPT(x) => { return this.java_ty(x, true); },
        .RESULT(e, x) => { return this.java_ty(x, boxed); },
        .CLOSURE(i) => { return fmt("Callback{}", unum(@cast<u64>(i))); },
        default => { return S("MemorySegment"); },
    }
}

// the Java expression for a value of type t read from segment seg at offset off
attach fn java_read(this: bind&, t: u32, seg: str, off: u64) -> std::string {
    match (this.shape_of(t) ?? shape::VOID) {
        .STRUCT(s) => { return fmt3("{}.read({}.asSlice({}))", this.local(this.c.si(s).name), S(seg), unum(off)); },
        .ENUM(e) => { return fmt4("{}.of({}.get({}, {}))", this.local(this.c.ei(e).name), S(seg), this.java_vl(t), unum(off)); },
        default => { return fmt3("{}.get({}, {})", S(seg), this.java_vl(t), unum(off)); },
    }
}

// the Java statement writing value v (of type t) into segment seg at offset off
attach fn java_write(this: bind&, t: u32, seg: str, off: u64, v: str) -> std::string {
    match (this.shape_of(t) ?? shape::VOID) {
        .STRUCT(s) => { return fmt3("{}.write({}.asSlice({}));", S(v), S(seg), unum(off)); },
        .ENUM(e) => { return fmt4("{}.set({}, {}, {}.value);", S(seg), this.java_vl(t), unum(off), S(v)); },
        default => { return fmt4("{}.set({}, {}, {});", S(seg), this.java_vl(t), unum(off), S(v)); },
    }
}

// can a value of type t be a field of a Java mirror class, an array element, or a callback argument
attach fn java_simple(this: bind&, t: u32) -> bool {
    match (this.shape_of(t) ?? shape::VOID) {
        .BOOL => { return true; },
        .INT(k) => { return true; },
        .FLOAT(b) => { return true; },
        .ENUM(e) => { return true; },
        .CODE => { return true; },
        .STRUCT(s) => {
            for (f&) in this.c.si(s).fields.items() {
                if (!this.java_simple(f.ty)) {
                    return false;
                }
            }
            return true;
        },
        default => { return false; },
    }
}

// one argument: its declaration, what the downcall gets, statements before and after
struct java_arg {
    decl: std::string = {};
    pass: std::string = {};
    before: std::string = {};
    after: std::string = {};
}

attach fn java_arg_of(this: bind&, t: u32, name: str, a: java_arg&) -> void {
    val h = this.lent_handle(t);
    if (h) {
        a.decl = fmt2("{} {}", this.local(this.c.si(h).name), S(name));
        a.pass = fmt("{}.handle()", S(name));
        return;
    }
    match (this.shape_of(t) ?? shape::VOID) {
        .STR => {
            a.decl = fmt("String {}", S(name));
            a.before = fmt2("MemorySegment {}_s = str(arena, {});\n", S(name), S(name));
            a.pass = fmt("{}_s", S(name));
        },
        .CSTR => {
            a.decl = fmt("String {}", S(name));
            a.pass = fmt3("({} == null ? MemorySegment.NULL : arena.allocateFrom({}))", S(name), S(name), S(""));
        },
        .ENUM(e) => {
            a.decl = fmt2("{} {}", this.local(this.c.ei(e).name), S(name));
            a.pass = fmt2("({}) {}.value", this.java_ty(int_id(this.c.ei(e).tag), false), S(name));
        },
        .STRUCT(s) => {
            a.decl = fmt2("{} {}", this.local(this.c.si(s).name), S(name));
            a.before = fmt3("MemorySegment {}_s = arena.allocate(L_{});\n{}.write(", S(name), this.local(this.c.si(s).name), S(name));
            a.before.append(fmt("{}_s);\n", S(name)).as_str());
            a.pass = fmt("{}_s", S(name));
        },
        .PTR(x) => {
            if (x != VOID) {
                match (this.shape_of(x) ?? shape::VOID) {
                    .STRUCT(s) => {
                        // a copy goes in, and what Volt changed comes back
                        a.decl = fmt2("{} {}", this.local(this.c.si(s).name), S(name));
                        a.before = fmt3("MemorySegment {}_s = {} == null ? MemorySegment.NULL : arena.allocate(L_{});\n", S(name), S(name), this.local(this.c.si(s).name));
                        a.before.append(fmt2("if ({} != null) {{\n    {}.write(", S(name), S(name)).as_str());
                        a.before.append(fmt("{}_s);\n}\n", S(name)).as_str());
                        a.pass = fmt("{}_s", S(name));
                        a.after = fmt3("if ({} != null) {{\n    {}.load({}_s);\n}}\n", S(name), S(name), S(name));
                        return;
                    },
                    default => {},
                }
            }
            a.decl = fmt("MemorySegment {}", S(name));
            a.pass = S(name);
        },
        .SLICE(x) => {
            val z = this.csize(x);
            a.decl = fmt2("{}[] {}", this.java_ty(x, false), S(name));
            a.before = fmt3("MemorySegment {}_e = arena.allocate({}L * Math.max(1, {}.length), ", S(name), unum(z.size), S(name));
            a.before.append(fmt3("{});\nfor (int i = 0; i < {}.length; i++) {{\n    ", unum(z.align), S(name), S("")).as_str());
            a.before.append(this.java_write(x, fmt("{}_e", S(name)).as_str(), 0, fmt("{}[i]", S(name)).as_str()).as_str());
            a.before = replace_off(a.before.as_str(), unum(z.size).as_str());
            a.before.append(fmt3("\n}}\nMemorySegment {}_s = arena.allocate(L_SLICE);\n{}_s.set(ADDRESS, 0, {}_e);\n", S(name), S(name), S(name)).as_str());
            a.before.append(fmt2("{}_s.set(JAVA_LONG, 8, {}.length);\n", S(name), S(name)).as_str());
            a.pass = fmt("{}_s", S(name));
            // what Volt wrote into the elements comes back
            var back = this.java_read(x, fmt("{}_e", S(name)).as_str(), 0);
            back = replace_off(back.as_str(), unum(z.size).as_str());
            a.after = fmt3("for (int i = 0; i < {}.length; i++) {{\n    {}[i] = {};\n}}\n", S(name), S(name), move back);
        },
        .OPT(x) => {
            a.decl = fmt2("{} {}", this.java_ty(x, true), S(name));
            a.before = fmt2("MemorySegment {}_s = arena.allocate({});\n", S(name), this.java_layout(t));
            a.before.append(fmt2("if ({} != null) {{\n    {}\n", S(name), this.java_write(x, fmt("{}_s", S(name)).as_str(), 0, S(name).as_str())).as_str());
            a.before.append(fmt2("    {}_s.set(JAVA_BOOLEAN, {}, true);\n}}\n", S(name), unum(this.csize(x).size)).as_str());
            a.pass = fmt("{}_s", S(name));
        },
        .CLOSURE(i) => {
            a.decl = fmt2("Callback{} {}", unum(@cast<u64>(i)), S(name));
            // an upcall that catches what the callback throws; it's rethrown after the call
            a.before = fmt3("Throwable[] {}_err = new Throwable[1];\nMemorySegment {}_up = upcall{}(", S(name), S(name), unum(@cast<u64>(i)));
            a.before.append(fmt3("arena, {}, {}_err);\n", S(name), S(name), S("")).as_str());
            a.pass = fmt("{}_up, MemorySegment.NULL", S(name));
            a.after = fmt("rethrow({}_err[0]);\n", S(name));
        },
        default => {
            a.decl = fmt2("{} {}", this.java_ty(t, false), S(name));
            a.pass = S(name);
        },
    }
}

// array element code uses offset 0 with "i * SIZE" added: replaced here
fn replace_off(s: str, size: str) -> std::string {
    var out: std::string = {};
    var i: usize = 0;
    val pat = ", 0)";
    val pat2 = ", 0, ";
    while (i < s.len) {
        if (i + pat.len <= s.len && s[i..i + pat.len] == pat) {
            out.append(fmt(", i * {}L)", S(size)).as_str());
            i += pat.len;
        } else if (i + pat2.len <= s.len && s[i..i + pat2.len] == pat2) {
            out.append(fmt(", i * {}L, ", S(size)).as_str());
            i += pat2.len;
        } else {
            out.push(s[i]);
            i += 1;
        }
    }
    return out;
}

// the descriptor of an export fn's downcall
attach fn java_desc(this: bind&, f: u32) -> std::string {
    val info = this.c.fi(f);
    var args: std::string = {};
    for (p&) in info.params.items() {
        if (args.len() > 0) {
            args.append(", ");
        }
        match (this.shape_of(p.ty) ?? shape::VOID) {
            .CLOSURE(i) => { args.append("ADDRESS, ADDRESS"); },
            default => { args.append(this.java_layout(p.ty).as_str()); },
        }
    }
    if (info.ret == VOID) {
        return fmt("FunctionDescriptor.ofVoid({})", move args);
    }
    if (args.len() > 0) {
        return fmt2("FunctionDescriptor.of({}, {})", this.java_layout(info.ret), move args);
    }
    return fmt("FunctionDescriptor.of({})", this.java_layout(info.ret));
}

// the Java cast for invokeExact's result
attach fn java_carrier(this: bind&, t: u32) -> std::string {
    if (this.java_is_struct(t)) {
        return S("MemorySegment");
    }
    match (this.shape_of(t) ?? shape::VOID) {
        .BOOL => { return S("boolean"); },
        .INT(k) => {
            val b = k.bits();
            if (b == 8) {
                return S("byte");
            }
            if (b == 16) {
                return S("short");
            }
            if (b == 32) {
                return S("int");
            }
            return S("long");
        },
        .FLOAT(b) => {
            if (b == 32) {
                return S("float");
            }
            return S("double");
        },
        .ENUM(e) => { return this.java_carrier(int_id(this.c.ei(e).tag)); },
        .CODE => { return S("int"); },
        default => { return S("MemorySegment"); },
    }
}

// the Java value of downcall result r (of type t)
attach fn java_value(this: bind&, t: u32, r: str) -> std::string {
    match (this.shape_of(t) ?? shape::VOID) {
        .STR => { return fmt("text({})", S(r)); },
        .CSTR => { return fmt3("({}.equals(MemorySegment.NULL) ? null : {}.reinterpret(Long.MAX_VALUE).getString(0))", S(r), S(r), S("")); },
        .TEXT(x) => { return fmt("take({})", S(r)); },
        .ENUM(e) => { return fmt2("{}.of({})", this.local(this.c.ei(e).name), S(r)); },
        .STRUCT(s) => { return fmt2("{}.read({})", this.local(this.c.si(s).name), S(r)); },
        .HANDLE(s) => { return fmt2("new {}({})", this.local(this.c.si(s).name), S(r)); },
        .OPT(x) => {
            return fmt3("({}.get(JAVA_BOOLEAN, {}) ? {} : null)", S(r), unum(this.csize(x).size), this.java_read(x, r, 0));
        },
        .SLICE(x) => {
            val z = this.csize(x);
            var el = this.java_read(x, "e", 0);
            el = replace_off(el.as_str(), unum(z.size).as_str());
            return fmt3("slice_{}({}, (e, i) -> {})", this.short(x), S(r), move el);
        },
        default => { return S(r); },
    }
}

// a wrapper's body
attach fn java_body(this: bind&, f: u32, args: std::vec<java_arg>&, self_pass: str?) -> std::string {
    val info = this.c.fi(f);
    var passes: std::string = {};
    var before: std::string = {};
    var after: std::string = {};
    if (this.java_is_struct(info.ret)) {
        passes.append("(SegmentAllocator) arena");
    }
    val sp = self_pass;
    if (sp) {
        if (passes.len() > 0) {
            passes.append(", ");
        }
        passes.append(sp);
    }
    for (a&) in args.items() {
        if (passes.len() > 0) {
            passes.append(", ");
        }
        passes.append(a.pass.as_str());
        before.append(a.before.as_str());
        after.append(a.after.as_str());
    }
    var out = S("try (Arena arena = Arena.ofConfined()) {\n");
    out.append(indent(before.as_str()).as_str());
    val call = fmt2("H_{}.invokeExact({})", S(info.c_name), move passes);
    if (info.ret == VOID) {
        out.append(fmt("    {};\n", move call).as_str());
    } else {
        out.append(fmt2("    var r = ({}) {};\n", this.java_carrier(info.ret), move call).as_str());
    }
    match (this.shape_of(info.ret) ?? shape::VOID) {
        .RESULT(e, x) => {
            out.append("    int code = r.get(JAVA_INT, 0);\n    if (code != 0) {\n        throw VoltException.of(code);\n    }\n");
            out.append(indent(after.as_str()).as_str());
            if (x != VOID) {
                val off = align_to(4, this.csize(x).align);
                var v = this.java_read(x, "r", off);
                match (this.shape_of(x) ?? shape::VOID) {
                    .TEXT(y) => { v = fmt2("take(r.asSlice({}, L_TEXT))", unum(off), S("")); },
                    .HANDLE(s) => { v = fmt3("new {}(r.get(ADDRESS, {}))", this.local(this.c.si(s).name), unum(off), S("")); },
                    .STR => { v = fmt("text(r.asSlice({}, L_STR))", unum(off)); },
                    default => {},
                }
                out.append(fmt("    return {};\n", move v).as_str());
            }
        },
        .VOID => { out.append(indent(after.as_str()).as_str()); },
        default => {
            out.append(indent(after.as_str()).as_str());
            out.append(fmt("    return {};\n", this.java_value(info.ret, "r")).as_str());
        },
    }
    out.append("} catch (RuntimeException | Error e) {\n    throw e;\n} catch (Throwable e) {\n    throw new RuntimeException(e);\n}\n");
    return out;
}

attach fn java_args(this: bind&, f: u32, first: usize) -> std::vec<java_arg> {
    val info = this.c.fi(f);
    var out: std::vec<java_arg> = {};
    for (k) in first..info.params.len {
        var a: java_arg = {};
        this.java_arg_of(info.params.at(k).ty, java_ident(info.params.at(k).name).as_str(), &a);
        put(&out, move a);
    }
    return out;
}

fn java_keyword(s: str) -> bool {
    val words: str[] = { "abstract", "assert", "boolean", "break", "byte", "case", "catch", "char", "class", "const", "continue", "default", "do", "double", "else", "enum", "extends", "final", "finally", "float", "for", "goto", "if", "implements", "import", "instanceof", "int", "interface", "long", "native", "new", "package", "private", "protected", "public", "return", "short", "static", "strictfp", "super", "switch", "synchronized", "this", "throw", "throws", "transient", "try", "void", "volatile", "while", "var", "record", "yield", "true", "false", "null" };
    for (w) in words {
        if (w == s) {
            return true;
        }
    }
    return false;
}

fn java_ident(s: str) -> std::string {
    var n = S(s);
    if (java_keyword(s)) {
        n.push('_');
    }
    return n;
}

fn java_decls(args: std::vec<java_arg>&) -> std::string {
    var s: std::string = {};
    for (a&) in args.items() {
        if (s.len() > 0) {
            s.append(", ");
        }
        s.append(a.decl.as_str());
    }
    return s;
}

attach fn java_doc(this: bind&, f: u32) -> std::string {
    val sp = this.c.dl(this.c.fi(f).decl).item.span;
    val d = doc_above(this.c.files.at(sp.file).text, @cast<usize>(sp.lo));
    if (d.len() == 0) {
        return {};
    }
    return fmt("/** {} */\n", move d);
}

attach fn java_text(this: bind&) -> std::string {
    val ents = this.entries();
    val cls = this.pkg;
    var out = fmt("// {}: generated by voltc bindings; the Volt package for Java 22+, through the FFM API\n", S(cls));
    out.append(fmt2("// (java.lang.foreign). It loads lib{}.so (or the library -Dvolt.{}.lib names); run with\n", S(cls), S(cls)).as_str());
    out.append("// --enable-native-access=ALL-UNNAMED. Errors are thrown as VoltException, one subclass per error set.\nimport java.lang.foreign.*;\nimport java.lang.invoke.*;\nimport java.lang.ref.Cleaner;\nimport java.nio.charset.StandardCharsets;\nimport static java.lang.foreign.ValueLayout.*;\n\n");
    // restricted: the FFM calls (allowed with --enable-native-access); try: an arena a call doesn't use
    out.append(fmt2("@SuppressWarnings({{\"restricted\", \"try\"}})\npublic final class {} {{\n    private {}() {{}}\n\n", S(cls), S(cls)).as_str());
    out.append("    private static final Linker LINKER = Linker.nativeLinker();\n");
    out.append(fmt2("    private static final SymbolLookup LIB = SymbolLookup.libraryLookup(System.getProperty(\"volt.{}.lib\", System.mapLibraryName(\"{}\")), Arena.global());\n", S(cls), S(cls)).as_str());
    out.append("    private static final Cleaner CLEANER = Cleaner.create();\n");
    out.append("    static final StructLayout L_STR = MemoryLayout.structLayout(ADDRESS.withName(\"ptr\"), JAVA_LONG.withName(\"len\"));\n");
    out.append("    static final StructLayout L_SLICE = MemoryLayout.structLayout(ADDRESS.withName(\"ptr\"), JAVA_LONG.withName(\"len\"));\n");
    out.append("    static final StructLayout L_TEXT = MemoryLayout.structLayout(ADDRESS.withName(\"ptr\"), JAVA_LONG.withName(\"len\"), ADDRESS.withName(\"owner\"), ADDRESS.withName(\"drop\"));\n");
    out.append("    private static final MethodHandle CALL_DROP = LINKER.downcallHandle(FunctionDescriptor.ofVoid(ADDRESS));\n\n");
    out.append("    // a String as a Volt str (UTF-8 in arena)\n    static MemorySegment str(Arena arena, String s) {\n        byte[] b = s.getBytes(StandardCharsets.UTF_8);\n        MemorySegment bytes = arena.allocate(Math.max(1, b.length));\n        MemorySegment.copy(b, 0, bytes, JAVA_BYTE, 0, b.length);\n        MemorySegment v = arena.allocate(L_STR);\n        v.set(ADDRESS, 0, bytes);\n        v.set(JAVA_LONG, 8, b.length);\n        return v;\n    }\n\n");
    out.append("    // a Volt str's text\n    static String text(MemorySegment v) {\n        long len = v.get(JAVA_LONG, 8);\n        byte[] b = v.get(ADDRESS, 0).reinterpret(len).toArray(JAVA_BYTE);\n        return new String(b, StandardCharsets.UTF_8);\n    }\n\n");
    out.append("    // owned text: copied out, then freed\n    static String take(MemorySegment t) {\n        String s = text(t);\n        MemorySegment drop = t.get(ADDRESS, 24);\n        if (!drop.equals(MemorySegment.NULL)) {\n            try {\n                CALL_DROP.invokeExact(drop, t.get(ADDRESS, 16));\n            } catch (Throwable e) {\n                throw new RuntimeException(e);\n            }\n        }\n        return s;\n    }\n\n");
    out.append("    static void rethrow(Throwable t) {\n        if (t instanceof RuntimeException e) {\n            throw e;\n        }\n        if (t instanceof Error e) {\n            throw e;\n        }\n        if (t != null) {\n            throw new RuntimeException(t);\n        }\n    }\n\n");
    out.append("    static MethodHandle find(String name, FunctionDescriptor d) {\n        return LINKER.downcallHandle(LIB.find(name).orElseThrow(() -> new UnsatisfiedLinkError(name)), d);\n    }\n");
    // errors
    out.append("\n    /** an error a Volt function returned: its code and name */\n    public static class VoltException extends RuntimeException {\n        private static final long serialVersionUID = 1L;\n        public final int code;\n        public final String name;\n\n        public VoltException(int code, String name) {\n            super(name);\n            this.code = code;\n            this.name = name;\n        }\n\n        static VoltException of(int code) {\n            switch (code) {\n");
    for (c&) in this.all_codes().items() {
        out.append(fmt3("                case (int) {}L: return new {}(code, \"{}\");\n", num(c.code), copy c.set, S(c.name)).as_str());
    }
    out.append("                default: return new VoltException(code, \"error\");\n            }\n        }\n    }\n");
    for (et&) in this.codes.items() {
        match (*this.c.t.get(*et)) {
            .ENUM(e) => {
                val info = this.c.ei(e);
                val n = this.local(info.name);
                out.append(fmt3("\n    /** error set {}: thrown for its errors; its codes */\n    public static final class {} extends VoltException {{\n        private static final long serialVersionUID = 1L;\n\n        public {}(int code, String name) {{\n            super(code, name);\n        }}\n\n", S(info.name), copy n, copy n).as_str());
                for (i) in 0..info.names.len {
                    out.append(fmt2("        public static final int {} = (int) {}L;\n", S(*info.names.at(i)), num(*info.values.at(i))).as_str());
                }
                out.append("    }\n");
            },
            default => {},
        }
    }
    // enums
    for (e&) in this.enums.items() {
        val info = this.c.ei(*e);
        val n = this.local(info.name);
        out.append(fmt("\n    public enum {} {{\n", copy n).as_str());
        for (i) in 0..info.names.len {
            var sep = ",";
            if (i + 1 == info.names.len) {
                sep = ";";
            }
            out.append(fmt3("        {}({}){}\n", S(*info.names.at(i)), num(*info.values.at(i)), S(sep)).as_str());
        }
        out.append(fmt2("\n        public final int value;\n\n        {}(int value) {{\n            this.value = value;\n        }}\n\n        static {} of(int v) {{\n            for (var x : values()) {{\n                if (x.value == v) {{\n                    return x;\n                }}\n            }}\n            throw new IllegalArgumentException(\"no such value: \" + v);\n        }}\n    }}\n", copy n, copy n).as_str());
    }
    // structs: mutable mirrors with their layouts
    for (s&) in this.structs.items() {
        val info = this.c.si(*s);
        val n = this.local(info.name);
        if (!this.java_simple(this.c.t.intern(tyk::STRUCT(*s)))) {
            continue;
        }
        out.append(fmt("\n    public static final class {} {{\n", copy n).as_str());
        var fields: std::string = {};
        var ctor_ps: std::string = {};
        var ctor_body: std::string = {};
        var layout = S("MemoryLayout.structLayout(");
        var off: u64 = 0;
        var reads: std::string = {};
        var writes: std::string = {};
        var first = true;
        for (f&) in info.fields.items() {
            val z = this.csize(f.ty);
            val at = align_to(off, z.align);
            if (!first) {
                layout.append(", ");
                ctor_ps.append(", ");
            }
            first = false;
            if (at > off) {
                layout.append(fmt("MemoryLayout.paddingLayout({}), ", unum(at - off)).as_str());
            }
            layout.append(fmt2("{}.withName(\"{}\")", this.java_layout(f.ty), S(f.name)).as_str());
            val fname = java_ident(f.name);
            fields.append(fmt2("        public {} {};\n", this.java_ty(f.ty, false), copy fname).as_str());
            ctor_ps.append(fmt2("{} {}", this.java_ty(f.ty, false), copy fname).as_str());
            ctor_body.append(fmt2("            this.{} = {};\n", copy fname, copy fname).as_str());
            reads.append(fmt2("            this.{} = {};\n", copy fname, this.java_read(f.ty, "s", at)).as_str());
            writes.append(fmt("            {}\n", this.java_write(f.ty, "s", at, fmt("this.{}", copy fname).as_str())).as_str());
            off = at + z.size;
        }
        val total = this.struct_size(*s).size;
        if (total > off) {
            layout.append(fmt(", MemoryLayout.paddingLayout({})", unum(total - off)).as_str());
        }
        layout.push(')');
        out.append(fields.as_str());
        out.append(fmt3("\n        public {}() {{}}\n\n        public {}({}) {{\n", copy n, copy n, move ctor_ps).as_str());
        out.append(ctor_body.as_str());
        out.append("        }\n\n        void load(MemorySegment s) {\n");
        out.append(reads.as_str());
        out.append(fmt3("        }}\n\n        static {} read(MemorySegment s) {{\n            var v = new {}();\n            v.load(s);\n            return v;\n        }}\n\n        void write(MemorySegment s) {{\n", copy n, copy n, S("")).as_str());
        out.append(writes.as_str());
        out.append("        }\n    }\n");
        out.append(fmt2("\n    static final StructLayout L_{} = {};\n", copy n, move layout).as_str());
    }
    // callbacks
    for (i) in 0..this.closures.len {
        match (*this.c.t.get(*this.closures.at(i))) {
            .FN_VAL(ps&, r) => {
                var params: std::string = {};
                var cparams = S("MemorySegment user");
                var largs: std::string = {};
                var vls: std::string = {};
                // the target's method type: its result, the bound f and err, then the C parameters
                var mt = fmt("{}.class", this.java_carrier(r));
                if (r == VOID) {
                    mt = S("void.class");
                }
                mt.append(fmt(", Callback{}.class, Throwable[].class, MemorySegment.class", unum(@cast<u64>(i))).as_str());
                for (k) in 0..ps.len {
                    val p = *ps.at(k);
                    if (k > 0) {
                        params.append(", ");
                        largs.append(", ");
                    }
                    params.append(fmt2("{} a{}", this.java_ty(p, false), unum(@cast<u64>(k))).as_str());
                    cparams.append(fmt2(", {} a{}", this.java_carrier(p), unum(@cast<u64>(k))).as_str());
                    match (this.shape_of(p) ?? shape::VOID) {
                        .ENUM(e) => { largs.append(fmt2("{}.of(a{})", this.local(this.c.ei(e).name), unum(@cast<u64>(k))).as_str()); },
                        .STR => { largs.append(fmt("text(a{}.reinterpret(L_STR.byteSize()))", unum(@cast<u64>(k))).as_str()); },
                        .STRUCT(s) => { largs.append(fmt2("{}.read(a{})", this.local(this.c.si(s).name), unum(@cast<u64>(k))).as_str()); },
                        default => { largs.append(fmt("a{}", unum(@cast<u64>(k))).as_str()); },
                    }
                    vls.append(", ");
                    vls.append(this.java_layout(p).as_str());
                    mt.append(fmt(", {}.class", this.java_carrier(p)).as_str());
                }
                val ii = unum(@cast<u64>(i));
                out.append(fmt3("\n    /** a callback: {} */\n    @FunctionalInterface\n    public interface Callback{} {{\n        ", this.c.ty_name(*this.closures.at(i)), copy ii, S("")).as_str());
                out.append(fmt3("{} call({});\n    }}\n", this.java_ty(r, false), move params, S("")).as_str());
                // the upcall target: calls f, keeping the first exception for after the call
                var target_ret = this.java_carrier(r);
                if (r == VOID) {
                    target_ret = S("void");
                }
                out.append(fmt3("\n    private static {} call{}(Callback{} f, Throwable[] err, ", move target_ret, copy ii, copy ii).as_str());
                out.append(fmt("{}) {{\n        try {{\n            ", move cparams).as_str());
                if (r == VOID) {
                    out.append(fmt("f.call({});\n", move largs).as_str());
                } else {
                    match (this.shape_of(r) ?? shape::VOID) {
                        .ENUM(e) => { out.append(fmt2("return ({}) f.call({}).value;\n", this.java_carrier(r), move largs).as_str()); },
                        default => { out.append(fmt("return f.call({});\n", move largs).as_str()); },
                    }
                }
                out.append("        } catch (Throwable t) {\n            if (err[0] == null) {\n                err[0] = t;\n            }\n");
                if (r != VOID) {
                    out.append(fmt("            return ({}) 0;\n", this.java_carrier(r)).as_str());
                }
                out.append("        }\n    }\n");
                var desc = S("FunctionDescriptor.ofVoid(ADDRESS");
                if (r != VOID) {
                    desc = fmt("FunctionDescriptor.of({}, ADDRESS", this.java_layout(r));
                }
                desc.append(vls.as_str());
                desc.push(')');
                out.append(fmt4("\n    private static MemorySegment upcall{}(Arena arena, Callback{} f, Throwable[] err) {{\n        try {{\n            MethodHandle h = MethodHandles.lookup().findStatic({}.class, \"call{}\", ", copy ii, copy ii, S(cls), copy ii).as_str());
                out.append(fmt2("MethodType.methodType({}));\n            h = MethodHandles.insertArguments(h, 0, f, err);\n            return LINKER.upcallStub(h, {}, arena);\n", move mt, move desc).as_str());
                out.append("        } catch (ReflectiveOperationException e) {\n            throw new RuntimeException(e);\n        }\n    }\n");
            },
            default => {},
        }
    }
    // slices that come back
    for (x&) in this.slices.items() {
        val et = this.java_ty(*x, false);
        val sh = this.short(*x);
        if (!this.java_simple(*x)) {
            continue;
        }
        out.append(fmt4("\n    interface Read_{} {{\n        {} get(MemorySegment e, long i);\n    }}\n\n    static {}[] slice_", copy sh, copy et, copy et, S("")).as_str());
        out.append(fmt3("{}(MemorySegment v, Read_{} read) {{\n        long n = v.get(JAVA_LONG, 8);\n        MemorySegment e = v.get(ADDRESS, 0).reinterpret(n * {}L);\n", copy sh, copy sh, unum(this.csize(*x).size)).as_str());
        out.append(fmt2("        {}[] out = new {}[(int) n];\n        for (int i = 0; i < n; i++) {{\n            out[i] = read.get(e, i);\n        }}\n        return out;\n    }}\n", copy et, copy et).as_str());
    }
    // the downcalls
    out.append("\n");
    for (e&) in ents.items() {
        val s = e.free_of;
        if (s) {
            out.append(fmt2("    static final MethodHandle H_{} = find(\"{}\", FunctionDescriptor.ofVoid(ADDRESS));\n", copy e.name, copy e.name).as_str());
            continue;
        }
        out.append(fmt3("    static final MethodHandle H_{} = find(\"{}\", {});\n", copy e.name, copy e.name, this.java_desc(e.f)).as_str());
    }
    // classes
    for (s&) in this.handles.items() {
        val n = this.local(this.c.si(*s).name);
        out.append(fmt4("\n    /** export struct {}: close() (or try-with-resources) frees it; otherwise it's freed once unreachable */\n    public static final class {} implements AutoCloseable {{\n        private final MemorySegment h;\n        private final Cleaner.Cleanable cleanable;\n\n        {}(MemorySegment h) {{\n            this.h = h;\n", S(this.c.si(*s).name), copy n, copy n, S("")).as_str());
        out.append(fmt("            this.cleanable = CLEANER.register(this, () -> free(h));\n        }\n\n        private static void free(MemorySegment h) {\n            try {\n                H_{}.invokeExact(h);\n            } catch (Throwable e) {\n                throw new RuntimeException(e);\n            }\n        }\n\n", this.free_name(*s)).as_str());
        out.append("        public void close() {\n            cleanable.clean();\n        }\n\n        MemorySegment handle() {\n            return h;\n        }\n");
        for (e&) in ents.items() {
            if (e.free_of != null) {
                continue;
            }
            val m = this.member_of(e.f, *s) ?? continue;
            val info = this.c.fi(e.f);
            out.append("\n");
            out.append(indent(indent(this.java_doc(e.f).as_str()).as_str()).as_str());
            if (this.node_is_method(e.f, *s)) {
                val args = this.java_args(e.f, 1);
                out.append(fmt3("        public {} {}({}) {{\n", this.java_ty(info.ret, false), java_ident(m), java_decls(&args)).as_str());
                out.append(indent(indent(indent(this.java_body(e.f, &args, "h").as_str()).as_str()).as_str()).as_str());
            } else if (m == "new") {
                val args = this.java_args(e.f, 0);
                var names: std::string = {};
                for (k) in 0..info.params.len {
                    if (k > 0) {
                        names.append(", ");
                    }
                    names.append(java_ident(info.params.at(k).name).as_str());
                }
                out.append(fmt3("        public {}({}) {{\n            this(make({}).h);\n", copy n, java_decls(&args), copy names).as_str());
                out.append(fmt3("        }}\n\n        private static {} make({}) {{\n", copy n, java_decls(&args), S("")).as_str());
                out.append(indent(indent(indent(this.java_body(e.f, &args, null).as_str()).as_str()).as_str()).as_str());
            } else {
                val args = this.java_args(e.f, 0);
                out.append(fmt3("        public static {} {}({}) {{\n", this.java_ty(info.ret, false), java_ident(m), java_decls(&args)).as_str());
                out.append(indent(indent(indent(this.java_body(e.f, &args, null).as_str()).as_str()).as_str()).as_str());
            }
            out.append("        }\n");
        }
        out.append("    }\n");
    }
    // the functions
    for (e&) in ents.items() {
        if (e.free_of != null || this.class_of(e.f) != null) {
            continue;
        }
        val info = this.c.fi(e.f);
        val args = this.java_args(e.f, 0);
        out.append("\n");
        out.append(indent(this.java_doc(e.f).as_str()).as_str());
        out.append(fmt3("    public static {} {}({}) {{\n", this.java_ty(info.ret, false), java_ident(info.c_name), java_decls(&args)).as_str());
        out.append(indent(indent(this.java_body(e.f, &args, null).as_str()).as_str()).as_str());
        out.append("    }\n");
    }
    out.append("}\n");
    return out;
}

// ---------- Go (cgo) ----------

// a Volt name as an exported Go name: ml_add -> MlAdd, NEGATIVE -> Negative
fn go_name(s: str) -> std::string {
    var out: std::string = {};
    var up = true;
    var all_upper = true;
    for (c) in s {
        if (c >= 'a' && c <= 'z') {
            all_upper = false;
        }
    }
    for (c) in s {
        if (c == '_' || c == ':') {
            up = true;
            continue;
        }
        if (up && c >= 'a' && c <= 'z') {
            out.push(c - 32);
        } else if (!up && all_upper && c >= 'A' && c <= 'Z') {
            out.push(c + 32);
        } else {
            out.push(c);
        }
        up = false;
    }
    return out;
}

// i32 -> int32, u8 -> uint8
fn go_int(k: int_ty) -> std::string {
    var s = S("int");
    if (!k.signed()) {
        s = S("uint");
    }
    s.append_uint(@cast<u64>(k.bits()));
    return s;
}

attach fn go_tname(this: bind&, name: str) -> std::string {
    return go_name(this.local(name).as_str());
}

// the Go type of a value of type t (plain types: as the wrappers take and give them)
attach fn go_ty(this: bind&, t: u32) -> std::string {
    val h = this.lent_handle(t);
    if (h) {
        return fmt("*{}", this.go_tname(this.c.si(h).name));
    }
    match (this.shape_of(t) ?? shape::VOID) {
        .VOID => { return {}; },
        .BOOL => { return S("bool"); },
        .INT(k) => {
            if (k == int_ty::USIZE) {
                return S("uint");
            }
            if (k == int_ty::ISIZE) {
                return S("int");
            }
            return go_int(k);
        },
        .FLOAT(b) => {
            if (b == 32) {
                return S("float32");
            }
            return S("float64");
        },
        .CSTR => { return S("string"); },
        .STR => { return S("string"); },
        .TEXT(x) => { return S("string"); },
        .ENUM(e) => { return this.go_tname(this.c.ei(e).name); },
        .CODE => { return S("uint32"); },
        .STRUCT(s) => { return this.go_tname(this.c.si(s).name); },
        .PTR(x) => {
            if (x != VOID) {
                match (this.shape_of(x) ?? shape::VOID) {
                    .STRUCT(s) => { return fmt("*{}", this.go_tname(this.c.si(s).name)); },
                    default => {},
                }
            }
            return S("unsafe.Pointer");
        },
        .HANDLE(s) => { return fmt("*{}", this.go_tname(this.c.si(s).name)); },
        .SLICE(x) => { return fmt("[]{}", this.go_ty(x)); },
        .OPT(x) => { return fmt("*{}", this.go_ty(x)); },
        .RESULT(e, x) => { return this.go_ty(x); },
        .CLOSURE(i) => {
            match (*this.c.t.get(t)) {
                .FN_VAL(ps&, r) => {
                    var s = S("func(");
                    for (k) in 0..ps.len {
                        if (k > 0) {
                            s.append(", ");
                        }
                        s.append(this.go_ty(*ps.at(k)).as_str());
                    }
                    s.push(')');
                    if (r != VOID) {
                        s.push(' ');
                        s.append(this.go_ty(r).as_str());
                    }
                    return s;
                },
                default => { return S("func()"); },
            }
        },
        default => { return S("unsafe.Pointer"); },
    }
}

// the C type cgo calls it (C.int32_t, C.mathlib_vec2...)
attach fn go_cty(this: bind&, t: u32) -> std::string {
    match (this.shape_of(t) ?? shape::VOID) {
        .BOOL => { return S("C.bool"); },
        .INT(k) => { return fmt("C.{}", S(int_c(k))); },
        .FLOAT(b) => {
            if (b == 32) {
                return S("C.float");
            }
            return S("C.double");
        },
        .ENUM(e) => { return fmt("C.{}", this.c_named(this.c.ei(e).name, false)); },
        .CODE => { return S("C.uint32_t"); },
        .STRUCT(s) => { return fmt("C.{}", this.c_named(this.c.si(s).name, false)); },
        .STR => { return S("C.volt_str"); },
        .TEXT(x) => { return S("C.volt_text"); },
        default => { return S("unsafe.Pointer"); },
    }
}

// is t a scalar whose Go and C forms have the same size (so a []T can be passed in place)
attach fn go_same_layout(this: bind&, t: u32) -> bool {
    match (this.shape_of(t) ?? shape::VOID) {
        .BOOL => { return true; },
        .INT(k) => { return true; },
        .FLOAT(b) => { return true; },
        .ENUM(e) => { return true; },
        .CODE => { return true; },
        default => { return false; },
    }
}

// the Go expression converting Go value v (of plain type t) to C
attach fn go_to_c(this: bind&, t: u32, v: str) -> std::string {
    match (this.shape_of(t) ?? shape::VOID) {
        .STRUCT(s) => { return fmt("{}.c()", S(v)); },
        default => { return fmt2("{}({})", this.go_cty(t), S(v)); },
    }
}

// the Go expression converting C value v (of plain type t) to Go
attach fn go_from_c(this: bind&, t: u32, v: str) -> std::string {
    match (this.shape_of(t) ?? shape::VOID) {
        .STRUCT(s) => { return fmt2("{}FromC({})", this.go_tname(this.c.si(s).name), S(v)); },
        .BOOL => { return fmt("bool({})", S(v)); },
        default => { return fmt2("{}({})", this.go_ty(t), S(v)); },
    }
}

attach fn go_plain(this: bind&, t: u32) -> bool {
    match (this.shape_of(t) ?? shape::VOID) {
        .BOOL => { return true; },
        .INT(k) => { return true; },
        .FLOAT(b) => { return true; },
        .ENUM(e) => { return true; },
        .CODE => { return true; },
        .STRUCT(s) => {
            for (f&) in this.c.si(s).fields.items() {
                if (!this.go_plain(f.ty)) {
                    return false;
                }
            }
            return true;
        },
        default => { return false; },
    }
}

struct go_arg {
    decl: std::string = {};
    pass: std::string = {};
    before: std::string = {};
    after: std::string = {};
}

attach fn go_arg_of(this: bind&, t: u32, name: str, a: go_arg&) -> void {
    val h = this.lent_handle(t);
    if (h) {
        a.decl = fmt2("{} {}", S(name), this.go_ty(t));
        a.pass = fmt("{}.handle()", S(name));
        a.after = fmt("runtime.KeepAlive({})\n", S(name));
        return;
    }
    if (this.go_plain(t)) {
        a.decl = fmt2("{} {}", S(name), this.go_ty(t));
        a.pass = this.go_to_c(t, name);
        return;
    }
    match (this.shape_of(t) ?? shape::VOID) {
        .STR => {
            a.decl = fmt("{} string", S(name));
            a.pass = fmt("goStr({})", S(name));
            a.after = fmt("runtime.KeepAlive({})\n", S(name));
        },
        .CSTR => {
            a.decl = fmt("{} string", S(name));
            a.before = fmt2("{}_c := C.CString({})\ndefer C.free(unsafe.Pointer(", S(name), S(name));
            a.before.append(fmt("{}_c))\n", S(name)).as_str());
            a.pass = fmt("{}_c", S(name));
        },
        .PTR(x) => {
            if (x != VOID) {
                match (this.shape_of(x) ?? shape::VOID) {
                    .STRUCT(s) => {
                        // a copy goes in, and what Volt changed comes back
                        val cn = this.c_named(this.c.si(s).name, false);
                        a.decl = fmt2("{} {}", S(name), this.go_ty(t));
                        a.before = fmt3("var {}_c *C.{}\nif {} != nil {{\n", S(name), copy cn, S(name));
                        a.before.append(fmt3("    v := {}.c()\n    {}_c = &v\n}}\n", S(name), S(name), S("")).as_str());
                        a.pass = fmt("{}_c", S(name));
                        a.after = fmt3("if {} != nil {{\n    *{} = {}FromC(*", S(name), S(name), this.go_tname(this.c.si(s).name));
                        a.after.append(fmt("{}_c)\n}\n", S(name)).as_str());
                        return;
                    },
                    default => {},
                }
            }
            a.decl = fmt("{} unsafe.Pointer", S(name));
            a.pass = S(name);
        },
        .SLICE(x) => {
            val sn = this.made_name("slice", x, false);
            a.decl = fmt2("{} {}", S(name), this.go_ty(t));
            if (this.go_same_layout(x)) {
                // the Go elements are the C elements: passed in place
                a.before = fmt4("var {}_p *{}\nif len({}) > 0 {{\n    {}_p = ", S(name), this.go_cty(x), S(name), S(name));
                a.before.append(fmt3("(*{})(unsafe.Pointer(&{}[0]))\n}}\n", this.go_cty(x), S(name), S("")).as_str());
                a.pass = fmt4("C.{}{{ptr: {}_p, len: C.size_t(len({}))}}", copy sn, S(name), S(name), S(""));
                a.after = fmt("runtime.KeepAlive({})\n", S(name));
            } else {
                // structs: a C copy, and what Volt wrote comes back
                a.before = fmt4("{}_c := make([]{}, len({}) + 1)\nfor i, v := range {} {{\n", S(name), this.go_cty(x), S(name), S(name));
                a.before.append(fmt2("    {}_c[i] = {}\n}}\n", S(name), this.go_to_c(x, "v")).as_str());
                a.pass = fmt4("C.{}{{ptr: &{}_c[0], len: C.size_t(len({}))}}", copy sn, S(name), S(name), S(""));
                a.after = fmt3("for i := range {} {{\n    {}[i] = ", S(name), S(name), S(""));
                a.after.append(fmt("{}\n}\n", this.go_from_c(x, fmt("{}_c[i]", S(name)).as_str())).as_str());
            }
        },
        .OPT(x) => {
            val on = this.made_name("opt", x, false);
            a.decl = fmt2("{} {}", S(name), this.go_ty(t));
            a.before = fmt3("var {}_c C.{}\nif {} != nil {{\n", S(name), copy on, S(name));
            a.before.append(fmt3("    {}_c.value = {}\n    {}_c.has = true\n}}\n", S(name), this.go_to_c(x, fmt("*{}", S(name)).as_str()), S(name)).as_str());
            a.pass = fmt("{}_c", S(name));
        },
        .CLOSURE(i) => {
            a.decl = fmt2("{} {}", S(name), this.go_ty(t));
            // the C side calls back through an exported Go function, which finds f by its handle
            a.before = fmt3("{}_s := &callback{{f: {}}}\n{}_h := cgo.NewHandle(", S(name), S(name), S(name));
            a.before.append(fmt2("{}_s)\ndefer {}_h.Delete()\n", S(name), S(name)).as_str());
            // a pointer to the handle (cgo's rule: C may use it during the call, and it holds no Go pointers)
            a.pass = fmt3("C.{}(C.{}cb{}), unsafe.Pointer(&", this.cb_name(i, false), S(this.pkg), unum(@cast<u64>(i)));
            a.pass.append(fmt("{}_h)", S(name)).as_str());
            a.after = fmt("{}_s.repanic()\n", S(name));
        },
        default => {
            a.decl = fmt2("{} {}", S(name), this.go_ty(t));
            a.pass = S(name);
        },
    }
}

// what a wrapper returns: Go result types, and whether it adds an error or a found flag
attach fn go_results(this: bind&, t: u32) -> std::string {
    match (this.shape_of(t) ?? shape::VOID) {
        .VOID => { return {}; },
        .RESULT(e, x) => {
            if (x == VOID) {
                return S(" error");
            }
            return fmt(" ({}, error)", this.go_ty(x));
        },
        .OPT(x) => { return fmt(" ({}, bool)", this.go_ty(x)); },
        default => { return fmt(" {}", this.go_ty(t)); },
    }
}

// the Go value of C result r (of type t)
attach fn go_value(this: bind&, t: u32, r: str) -> std::string {
    if (this.go_plain(t)) {
        return this.go_from_c(t, r);
    }
    match (this.shape_of(t) ?? shape::VOID) {
        .STR => { return fmt3("C.GoStringN((*C.char)(unsafe.Pointer({}.ptr)), C.int({}.len))", S(r), S(r), S("")); },
        .CSTR => { return fmt("C.GoString({})", S(r)); },
        .TEXT(x) => { return fmt("takeText({})", S(r)); },
        .HANDLE(s) => { return fmt2("wrap{}({})", this.go_tname(this.c.si(s).name), S(r)); },
        .SLICE(x) => {
            if (this.go_same_layout(x)) {
                return fmt4("append([]{}(nil), unsafe.Slice((*{})(unsafe.Pointer({}.ptr)), int({}.len))...)", this.go_ty(x), this.go_ty(x), S(r), S(r));
            }
            return fmt("nil /* {} */", this.c.ty_name(t));
        },
        default => { return S(r); },
    }
}

attach fn go_body(this: bind&, f: u32, args: std::vec<go_arg>&, self_pass: str?) -> std::string {
    val info = this.c.fi(f);
    var passes: std::string = {};
    var before: std::string = {};
    var after: std::string = {};
    val sp = self_pass;
    if (sp) {
        passes.append(sp);
        after.append("runtime.KeepAlive(o)\n");
    }
    for (a&) in args.items() {
        if (passes.len() > 0) {
            passes.append(", ");
        }
        passes.append(a.pass.as_str());
        before.append(a.before.as_str());
        after.append(a.after.as_str());
    }
    var out = move before;
    val call = fmt2("C.{}({})", S(info.c_name), move passes);
    if (info.ret == VOID) {
        out.append(fmt("{}\n", move call).as_str());
        out.append(after.as_str());
        return out;
    }
    out.append(fmt("r := {}\n", move call).as_str());
    out.append(after.as_str());
    match (this.shape_of(info.ret) ?? shape::VOID) {
        .RESULT(e, x) => {
            if (x == VOID) {
                out.append("if r.error != 0 {\n    return errorOf(uint32(r.error))\n}\nreturn nil\n");
            } else {
                out.append(fmt("if r.error != 0 {\n    var zero {}\n    return zero, errorOf(uint32(r.error))\n}\n", this.go_ty(x)).as_str());
                out.append(fmt("return {}, nil\n", this.go_value(x, "r.value")).as_str());
            }
        },
        .OPT(x) => {
            out.append(fmt("if !r.has {\n    var zero {}\n    return zero, false\n}\n", this.go_ty(x)).as_str());
            out.append(fmt("return {}, true\n", this.go_value(x, "r.value")).as_str());
        },
        default => { out.append(fmt("return {}\n", this.go_value(info.ret, "r")).as_str()); },
    }
    return out;
}

fn go_keyword(s: str) -> bool {
    val words: str[] = { "break", "case", "chan", "const", "continue", "default", "defer", "else", "fallthrough", "for", "func", "go", "goto", "if", "import", "interface", "map", "package", "range", "return", "select", "struct", "switch", "type", "var", "len", "cap", "new", "make", "error", "string" };
    for (w) in words {
        if (w == s) {
            return true;
        }
    }
    return false;
}

fn go_param(s: str) -> std::string {
    var n = S(s);
    if (go_keyword(s)) {
        n.push('_');
    }
    return n;
}

attach fn go_args(this: bind&, f: u32, first: usize) -> std::vec<go_arg> {
    val info = this.c.fi(f);
    var out: std::vec<go_arg> = {};
    for (k) in first..info.params.len {
        var a: go_arg = {};
        this.go_arg_of(info.params.at(k).ty, go_param(info.params.at(k).name).as_str(), &a);
        put(&out, move a);
    }
    return out;
}

fn go_decls(args: std::vec<go_arg>&) -> std::string {
    var s: std::string = {};
    for (a&) in args.items() {
        if (s.len() > 0) {
            s.append(", ");
        }
        s.append(a.decl.as_str());
    }
    return s;
}

attach fn go_doc(this: bind&, f: u32, name: str) -> std::string {
    val sp = this.c.dl(this.c.fi(f).decl).item.span;
    val d = doc_above(this.c.files.at(sp.file).text, @cast<usize>(sp.lo));
    if (d.len() == 0) {
        return {};
    }
    return fmt2("// {}: {}\n", S(name), move d);
}

attach fn go_text(this: bind&) -> std::string {
    val ents = this.entries();
    val p = this.pkg;
    var out = S("// Code generated by voltc bindings. DO NOT EDIT.\n\n");
    out.append(fmt("// Package {}: the Volt package for Go, through cgo. It links\n", S(p)).as_str());
    out.append(fmt("// lib{} (set CGO_LDFLAGS=-L<dir> for where it is). Errors come back as *Error values.\n", S(p)).as_str());
    out.append(fmt("package {}\n\n/*\n", S(p)).as_str());
    out.append(fmt("#cgo LDFLAGS: -l{}\n#include <stdlib.h>\n", S(p)).as_str());
    // only declarations here: this file exports Go functions to C, and cgo allows no C definitions
    // next to //export
    var hdr = this.c_text();
    hdr = without_inline_text_free(hdr.as_str());
    out.append(hdr.as_str());
    for (i) in 0..this.closures.len {
        match (*this.c.t.get(*this.closures.at(i))) {
            .FN_VAL(ps&, r) => {
                var params = S("void *user");
                for (k) in 0..ps.len {
                    params.append(fmt2(", {}a{}", spaced(this.c_prim(*ps.at(k), false)), unum(@cast<u64>(k))).as_str());
                }
                out.append(fmt4("extern {}{}cb{}({});\n", spaced(this.c_prim(r, false)), S(p), unum(@cast<u64>(i)), move params).as_str());
            },
            default => {},
        }
    }
    out.append("*/\nimport \"C\"\n\nimport (\n    \"fmt\"\n    \"runtime\"\n    \"runtime/cgo\"\n    \"unsafe\"\n)\n");
    out.append("\nvar _ = fmt.Sprint\nvar _ cgo.Handle\n");
    // errors
    out.append("\n// Error is an error a Volt function returned: its code and name. Each code is one value, so\n// errors.Is (or ==) against the package's Err... variables works.\ntype Error struct {\n    Code uint32\n    Name string\n}\n\nfunc (e *Error) Error() string { return e.Name }\n");
    var codes: std::string = {};
    for (c&) in this.all_codes().items() {
        val v = fmt2("{}{}", go_name(c.set.as_str()), go_name(c.name));
        out.append(fmt4("\n// {} is error {} of {}.\nvar {} = ", copy v, S(c.name), copy c.set, copy v).as_str());
        out.append(fmt2("&Error{{Code: {}, Name: \"{}\"}}\n", num(c.code), S(c.name)).as_str());
        codes.append(fmt3("    case {}:\n        return {}\n{}", num(c.code), copy v, S("")).as_str());
    }
    out.append(fmt("\nfunc errorOf(code uint32) error {\n    switch code {\n{}    }\n    return &Error{Code: code, Name: fmt.Sprint(\"error \", code)}\n}\n", move codes).as_str());
    // text and strings
    out.append("\n// a string as a Volt str (the bytes stay Go's; C only reads them during the call)\nfunc goStr(s string) C.volt_str {\n    return C.volt_str{ptr: (*C.uint8_t)(unsafe.Pointer(unsafe.StringData(s))), len: C.size_t(len(s))}\n}\n");
    if (this.texts.len > 0) {
        out.append(fmt("\nfunc takeText(t C.volt_text) string {\n    s := C.GoStringN((*C.char)(unsafe.Pointer(t.ptr)), C.int(t.len))\n    C.{}_text_free(t)\n    return s\n}\n", S(p)).as_str());
    }
    // enums
    for (e&) in this.enums.items() {
        val info = this.c.ei(*e);
        val n = this.go_tname(info.name);
        out.append(fmt2("\n// {} is Volt enum {}.\n", copy n, S(info.name)).as_str());
        out.append(fmt2("type {} {}\n\nconst (\n", copy n, this.go_ty(int_id(info.tag))).as_str());
        for (i) in 0..info.names.len {
            out.append(fmt4("    {}{} {} = {}\n", copy n, go_name(*info.names.at(i)), copy n, num(*info.values.at(i))).as_str());
        }
        out.append(")\n");
    }
    // structs
    for (s&) in this.structs.items() {
        if (!this.go_plain(this.c.t.intern(tyk::STRUCT(*s)))) {
            continue;
        }
        val info = this.c.si(*s);
        val n = this.go_tname(info.name);
        val cn = this.c_named(info.name, false);
        out.append(fmt2("\n// {} is Volt struct {}.\ntype ", copy n, S(info.name)).as_str());
        out.append(fmt("{} struct {{\n", copy n).as_str());
        var toc: std::string = {};
        var fromc: std::string = {};
        for (f&) in info.fields.items() {
            out.append(fmt2("    {} {}\n", go_name(f.name), this.go_ty(f.ty)).as_str());
            toc.append(fmt2("        {}: {},\n", S(f.name), this.go_to_c(f.ty, fmt("v.{}", go_name(f.name)).as_str())).as_str());
            fromc.append(fmt2("        {}: {},\n", go_name(f.name), this.go_from_c(f.ty, fmt("c.{}", S(f.name)).as_str())).as_str());
        }
        out.append(fmt3("}}\n\nfunc (v {}) c() C.{} {{\n    return C.{}{{\n", copy n, copy cn, copy cn).as_str());
        out.append(toc.as_str());
        out.append(fmt3("    }}\n}}\n\nfunc {}FromC(c C.{}) {} {{\n", copy n, copy cn, copy n).as_str());
        out.append(fmt("    return {}{{\n", copy n).as_str());
        out.append(fromc.as_str());
        out.append("    }\n}\n");
    }
    // callbacks: exported Go functions the C side calls with the handle of a callback
    if (this.closures.len > 0) {
        out.append("\n// a Go function passed for a callback, and what it panicked with (re-panicked after the call)\ntype callback struct {\n    f      any\n    panicked any\n}\n\nfunc (s *callback) repanic() {\n    if s.panicked != nil {\n        panic(s.panicked)\n    }\n}\n");
    }
    for (i) in 0..this.closures.len {
        val ct = *this.closures.at(i);
        match (*this.c.t.get(ct)) {
            .FN_VAL(ps&, r) => {
                var params = S("user unsafe.Pointer");
                var args: std::string = {};
                for (k) in 0..ps.len {
                    params.append(fmt2(", a{} {}", unum(@cast<u64>(k)), this.go_cty(*ps.at(k))).as_str());
                    if (k > 0) {
                        args.append(", ");
                    }
                    args.append(this.go_from_c(*ps.at(k), fmt("a{}", unum(@cast<u64>(k))).as_str()).as_str());
                }
                var ret: std::string = {};
                if (r != VOID) {
                    ret = fmt(" (out {})", this.go_cty(r));
                }
                out.append(fmt4("\n//export {}cb{}\nfunc {}cb{}(", S(p), unum(@cast<u64>(i)), S(p), unum(@cast<u64>(i))).as_str());
                out.append(fmt2("{}){} {{\n    s := (*cgo.Handle)(user).Value().(*callback)\n    defer func() {{\n        if v := recover(); v != nil && s.panicked == nil {{\n            s.panicked = v\n        }}\n    }}()\n", move params, move ret).as_str());
                if (r == VOID) {
                    out.append(fmt2("    s.f.({})({})\n", this.go_ty(ct), move args).as_str());
                    out.append("}\n");
                } else {
                    out.append(fmt2("    v := s.f.({})({})\n", this.go_ty(ct), move args).as_str());
                    out.append(fmt("    return {}\n}\n", this.go_to_c(r, "v")).as_str());
                }
            },
            default => {},
        }
    }
    // classes
    for (s&) in this.handles.items() {
        val n = this.go_tname(this.c.si(*s).name);
        val cn = this.c_named(this.c.si(*s).name, false);
        out.append(fmt3("\n// {} is Volt export struct {}. Close frees it (or the garbage collector does).\ntype {} struct {{\n", copy n, S(this.c.si(*s).name), copy n).as_str());
        out.append(fmt3("    h *C.{}\n}}\n\nfunc wrap{}(h *C.", copy cn, copy n, S("")).as_str());
        out.append(fmt4("{}) *{} {{\n    o := &{}{{h: h}}\n    runtime.SetFinalizer(o, (*{}).Close)\n    return o\n}}\n", copy cn, copy n, copy n, copy n).as_str());
        out.append(fmt3("\n// Close frees the handle (once; later calls do nothing).\nfunc (o *{}) Close() {{\n    if o.h != nil {{\n        C.{}(o.h)\n        o.h = nil\n        runtime.SetFinalizer(o, nil)\n    }}\n}}\n", copy n, this.free_name(*s), S("")).as_str());
        out.append(fmt2("\nfunc (o *{}) handle() *C.{} {{\n    if o.h == nil {{\n        panic(\"", copy n, copy cn).as_str());
        out.append(fmt2("{}: used after Close\")\n    }}\n    return o.h\n}}\n", copy n, S("")).as_str());
        for (e&) in ents.items() {
            if (e.free_of != null) {
                continue;
            }
            val m = this.member_of(e.f, *s) ?? continue;
            val info = this.c.fi(e.f);
            if (this.node_is_method(e.f, *s)) {
                val args = this.go_args(e.f, 1);
                out.append("\n");
                out.append(this.go_doc(e.f, go_name(m).as_str()).as_str());
                out.append(fmt4("func (o *{}) {}({}){} {{\n", copy n, go_name(m), go_decls(&args), this.go_results(info.ret)).as_str());
                out.append(indent(this.go_body(e.f, &args, "o.handle()").as_str()).as_str());
                out.append("}\n");
            } else {
                // New for new, NewX... for the others
                var fname = fmt("New{}", copy n);
                if (m != "new") {
                    fname = fmt2("{}{}", copy n, go_name(m));
                }
                val args = this.go_args(e.f, 0);
                out.append("\n");
                out.append(this.go_doc(e.f, fname.as_str()).as_str());
                out.append(fmt3("func {}({}){} {{\n", copy fname, go_decls(&args), this.go_results(info.ret)).as_str());
                out.append(indent(this.go_body(e.f, &args, null).as_str()).as_str());
                out.append("}\n");
            }
        }
    }
    // the functions
    for (e&) in ents.items() {
        if (e.free_of != null || this.class_of(e.f) != null) {
            continue;
        }
        val info = this.c.fi(e.f);
        val args = this.go_args(e.f, 0);
        val gn = go_name(info.c_name);
        out.append("\n");
        out.append(this.go_doc(e.f, gn.as_str()).as_str());
        out.append(fmt4("func {}({}){} {{\n{}", copy gn, go_decls(&args), this.go_results(info.ret), S("")).as_str());
        out.append(indent(this.go_body(e.f, &args, null).as_str()).as_str());
        out.append("}\n");
    }
    return out;
}

// the C header without its static inline volt_text_free (a definition)
fn without_inline_text_free(s: str) -> std::string {
    val start = "static inline void volt_text_free(volt_text t) {";
    var out: std::string = {};
    var i: usize = 0;
    while (i < s.len) {
        if (i + start.len <= s.len && s[i..i + start.len] == start) {
            // skip to the closing brace at the start of a line
            var j = i;
            while (j + 1 < s.len && !(s[j] == '\n' && s[j + 1] == '}')) {
                j += 1;
            }
            i = j + 2;
            continue;
        }
        out.push(s[i]);
        i += 1;
    }
    return out;
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
            return out;
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
    return out;
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
    return out;
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
    return out;
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
            return e;
        },
        .OPT(x) => {
            var v = this.ts_ty(x, incoming);
            v.append(" | null");
            if (incoming) {
                v.append(" | undefined");
            }
            return v;
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
                    return s;
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
    return ps;
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
    // a class's [Symbol.dispose] needs TypeScript's disposable lib, which an older --target (es2022)
    // doesn't load by itself: the file asks for it
    if (out.as_str().contains("[Symbol.dispose]")) {
        var top = S("/// <reference lib=\"esnext.disposable\" />\n");
        top.append(out.as_str());
        return top;
    }
    return out;
}

// ---------- Lua (5.4 and later): a C module ----------
// A Lua error longjmps, so nothing is held across one: a slice's elements live in a userdata (the
// collector frees them), and an owned result is freed before a callback's error is raised. A
// callback's Lua function runs in a protected call; its error is raised once the Volt call is back

// C statements reading the Lua value at stack index idx into C lvalue c (simple types: numbers,
// bool, enums, error codes and structs of those); what (a C string expression) names the value in
// the error raised when it doesn't fit
attach fn lua_get(this: bind&, t: u32, idx: str, c: str, what: str) -> std::string {
    match (this.shape_of(t) ?? shape::VOID) {
        .BOOL => { return fmt3("{} = vl_bool(L, {}, {});", S(c), S(idx), S(what)); },
        .FLOAT(b) => { return fmt4("{} = ({})vl_num(L, {}, {});", S(c), this.c_prim(t, false), S(idx), S(what)); },
        .INT(k) => { return fmt4("{} = ({})vl_int(L, {}, {});", S(c), this.c_prim(t, false), S(idx), fmt2("{}, {}", lua_limits(k), S(what))); },
        .ENUM(e) => { return fmt4("{} = ({})vl_int(L, {}, {});", S(c), this.c_prim(t, false), S(idx), fmt2("{}, {}", lua_limits(this.c.ei(e).tag), S(what))); },
        .CODE => { return fmt3("{} = (uint32_t)vl_int(L, {}, 0, UINT32_MAX, {});", S(c), S(idx), S(what)); },
        .STRUCT(s) => { return fmt4("vl_get_{}(L, {}, &{}, {});", this.node_sname(s), S(idx), S(c), S(what)); },
        default => { return S("luaL_error(L, \"unsupported\");"); },
    }
}

// the range of a C integer type, as two lua_Integer expressions
fn lua_limits(k: int_ty) -> std::string {
    match (k) {
        .I8 => { return S("INT8_MIN, INT8_MAX"); },
        .I16 => { return S("INT16_MIN, INT16_MAX"); },
        .I32 => { return S("INT32_MIN, INT32_MAX"); },
        .U8 => { return S("0, UINT8_MAX"); },
        .U16 => { return S("0, UINT16_MAX"); },
        .U32 => { return S("0, UINT32_MAX"); },
        .U64 => { return S("0, LUA_MAXINTEGER"); },
        .U128 => { return S("0, LUA_MAXINTEGER"); },
        .USIZE => { return S("0, LUA_MAXINTEGER"); },
        default => { return S("LUA_MININTEGER, LUA_MAXINTEGER"); },
    }
}

// a C statement pushing simple C value c (of type t)
attach fn lua_push(this: bind&, t: u32, c: str) -> std::string {
    match (this.shape_of(t) ?? shape::VOID) {
        .BOOL => { return fmt("lua_pushboolean(L, {});", S(c)); },
        .FLOAT(b) => { return fmt("lua_pushnumber(L, (lua_Number)({}));", S(c)); },
        .STRUCT(s) => { return fmt2("vl_new_{}(L, &{});", this.node_sname(s), S(c)); },
        default => { return fmt("lua_pushinteger(L, (lua_Integer)({}));", S(c)); },
    }
}

// one argument of an export fn: its C locals (decl), the statements that fill them from the Lua
// argument (get), what the call passes (pass), what writes changes back into Lua tables (after),
// and a callback's vl_cb (cb)
struct lua_arg {
    decl: std::string = {};
    get: std::string = {};
    pass: std::string = {};
    after: std::string = {};
    cb: std::string = {};
}

attach fn lua_arg_of(this: bind&, t: u32, idx: str, c: str, what: str, a: lua_arg&) -> compile_error!void {
    if (this.node_simple(t)) {
        a.decl = fmt2("{} {};", this.c_prim(t, false), S(c));
        a.get = this.lua_get(t, idx, c, what);
        a.pass = S(c);
        return;
    }
    val h = this.lent_handle(t);
    if (h) {
        a.decl = fmt2("{}{};", spaced(this.handle_c(h, false)), S(c));
        a.get = fmt4("{} = vl_check_{}(L, {}, {});", S(c), this.node_sname(h), S(idx), S(what));
        a.pass = S(c);
        return;
    }
    match (this.shape_of(t) ?? shape::VOID) {
        .STR => {
            a.decl = fmt("volt_str {};", S(c));
            a.get = fmt4("{}.ptr = (const uint8_t *)vl_str(L, {}, &{}.len, {});", S(c), S(idx), S(c), S(what));
            a.pass = S(c);
        },
        .CSTR => {
            a.decl = fmt("const char *{} = NULL;", S(c));
            a.get = fmt4("if (!lua_isnoneornil(L, {})) {{ {} = vl_str(L, {}, NULL, {}); }}", S(idx), S(c), S(idx), S(what));
            a.pass = S(c);
        },
        .PTR(x) => {
            if (x != VOID && this.node_simple(x)) {
                // a struct (or number) by reference: a copy goes in, and what Volt changed comes back
                // into the table (a number has nowhere to go back to)
                val v = fmt("{}_val", S(c));
                a.decl = fmt2("{} {};", this.c_prim(x, false), copy v);
                var nullable = true;
                match (*this.c.t.get(t)) {
                    .REF(y) => { nullable = false; },
                    default => {},
                }
                var back: std::string = {};
                match (this.shape_of(x) ?? shape::VOID) {
                    .STRUCT(s) => { back = fmt3("vl_set_{}(L, {}, &{});", this.node_sname(s), S(idx), copy v); },
                    default => {},
                }
                if (nullable) {
                    a.decl.append(fmt(" bool {}_null;", S(c)).as_str());
                    a.get = fmt4("{}_null = lua_isnoneornil(L, {}); if (!{}_null) {{ {} }}", S(c), S(idx), S(c), this.lua_get(x, idx, v.as_str(), what));
                    a.pass = fmt2("({}_null ? NULL : &{})", S(c), copy v);
                    if (back.len() > 0) {
                        a.after = fmt2("if (!{}_null) {{ {} }}", S(c), move back);
                    }
                } else {
                    a.get = this.lua_get(x, idx, v.as_str(), what);
                    a.pass = fmt("&{}", copy v);
                    a.after = move back;
                }
                return;
            }
            // anything else behind a pointer: a light userdata from another call
            a.decl = fmt2("{}{} = NULL;", spaced(this.c_prim(t, false)), S(c));
            a.get = fmt4("if (!lua_isnoneornil(L, {})) {{ {} = vl_pointer(L, {}, {}); }}", S(idx), S(c), S(idx), S(what));
            a.pass = S(c);
        },
        .SLICE(x) => {
            if (!this.node_simple(x)) {
                return fail(NO_SPAN, fmt("a slice of {} can't come from Lua (numbers, bool, enums and structs of those can)", this.c.ty_name(x)));
            }
            a.decl = fmt2("{} {};", this.c_prim(t, false), S(c));
            a.get = fmt4("{}.len = vl_seq(L, {}, {}); {}.ptr = ", S(c), S(idx), S(what), S(c));
            a.get.append(fmt3("lua_newuserdatauv(L, sizeof *{}.ptr * ({}.len ? {}.len : 1), 0);", S(c), S(c), S(c)).as_str());
            a.get.append(fmt3(" for (size_t i = 0; i < {}.len; i++) {{ lua_geti(L, {}, (lua_Integer)i + 1); {} lua_pop(L, 1); }}", S(c), S(idx), this.lua_get(x, "-1", fmt("{}.ptr[i]", S(c)).as_str(), what)).as_str());
            a.pass = S(c);
            // what Volt wrote into the elements comes back
            a.after = fmt3("for (size_t i = 0; i < {}.len; i++) {{ {} lua_seti(L, {}, (lua_Integer)i + 1); }}", S(c), this.lua_push(x, fmt("{}.ptr[i]", S(c)).as_str()), S(idx));
        },
        .OPT(x) => {
            if (!this.node_simple(x)) {
                return fail(NO_SPAN, fmt("an optional {} can't come from Lua (numbers, bool, enums and structs of those can)", this.c.ty_name(x)));
            }
            a.decl = fmt2("{} {};", this.c_prim(t, false), S(c));
            a.get = fmt4("memset(&{}, 0, sizeof {}); if (!lua_isnoneornil(L, {})) {{ {}.has = true; ", S(c), S(c), S(idx), S(c));
            a.get.append(fmt("{} }", this.lua_get(x, idx, fmt("{}.value", S(c)).as_str(), what)).as_str());
            a.pass = S(c);
        },
        .CLOSURE(i) => {
            a.decl = fmt("struct vl_cb {}_cb;", S(c));
            a.get = fmt4("luaL_checktype(L, {}, LUA_TFUNCTION); {}_cb.L = L; {}_cb.fn = {}; ", S(idx), S(c), S(c), S(idx));
            a.get.append(fmt("{}_cb.err = LUA_NOREF;", S(c)).as_str());
            a.pass = fmt2("vl_cb{}, &{}_cb", unum(@cast<u64>(i)), S(c));
            a.cb = fmt("{}_cb", S(c));
        },
        default => { return fail(NO_SPAN, fmt("{} can't come from Lua", this.c.ty_name(t))); },
    }
    return;
}

// statements pushing C result r (of type t), or raising its error
attach fn lua_result(this: bind&, t: u32, r: str) -> compile_error!std::string {
    if (t == VOID) {
        return {};
    }
    if (this.node_simple(t)) {
        return this.lua_push(t, r);
    }
    match (this.shape_of(t) ?? shape::VOID) {
        .STR => { return fmt2("lua_pushlstring(L, (const char *){}.ptr, {}.len);", S(r), S(r)); },
        .CSTR => { return fmt2("if ({}) {{ lua_pushstring(L, {}); }} else {{ lua_pushnil(L); }}", S(r), S(r)); },
        .TEXT(x) => { return fmt("vl_push_text(L, {});", S(r)); },
        .HANDLE(s) => { return fmt2("vl_wrap_{}(L, {});", this.node_sname(s), S(r)); },
        .OPT(x) => {
            if (!this.node_simple(x)) {
                return fail(NO_SPAN, fmt("an optional {} can't go to Lua", this.c.ty_name(x)));
            }
            return fmt2("if ({}.has) {{ {} }} else {{ lua_pushnil(L); }}", S(r), this.lua_push(x, fmt("{}.value", S(r)).as_str()));
        },
        .SLICE(x) => {
            if (!this.node_simple(x)) {
                return fail(NO_SPAN, fmt("a slice of {} can't go to Lua", this.c.ty_name(x)));
            }
            return fmt4("lua_createtable(L, {}.len < INT_MAX ? (int){}.len : 0, 0); for (size_t i = 0; i < {}.len; i++) {{ {} lua_seti(L, -2, (lua_Integer)i + 1); }}", S(r), S(r), S(r), this.lua_push(x, fmt("{}.ptr[i]", S(r)).as_str()));
        },
        .RESULT(e, x) => {
            var out = fmt2("if ({}.error != 0) {{ vl_raise(L, {}.error); }}", S(r), S(r));
            val value = try this.lua_result(x, fmt("{}.value", S(r)).as_str());
            if (value.len() > 0) {
                out.append(" ");
                out.append(value.as_str());
            }
            return out;
        },
        .PTR(x) => { return fmt2("if ({}) {{ lua_pushlightuserdata(L, (void *){}); }} else {{ lua_pushnil(L); }}", S(r), S(r)); },
        default => { return fail(NO_SPAN, fmt("{} can't go to Lua", this.c.ty_name(t))); },
    }
}

// what frees owned C result r (of type t) when a callback's error is raised instead
attach fn lua_drop(this: bind&, t: u32, r: str) -> std::string {
    match (this.shape_of(t) ?? shape::VOID) {
        .TEXT(x) => { return fmt("volt_text_free({}); ", S(r)); },
        .HANDLE(s) => { return fmt2("{}({}); ", this.free_name(s), S(r)); },
        .RESULT(e, x) => {
            val inner = this.lua_drop(x, fmt("{}.value", S(r)).as_str());
            if (inner.len() == 0) {
                return {};
            }
            return fmt2("if ({}.error == 0) {{ {}}} ", S(r), move inner);
        },
        default => { return {}; },
    }
}

// how many values a result of type t pushes
attach fn lua_count(this: bind&, t: u32) -> usize {
    match (this.shape_of(t) ?? shape::VOID) {
        .VOID => { return 0; },
        .RESULT(e, x) => { return this.lua_count(x); },
        default => { return 1; },
    }
}

// the C function behind one Lua function (a method's self is its argument 1)
attach fn lua_fn(this: bind&, f: u32, out: std::string&) -> compile_error!void {
    val info = this.c.fi(f);
    var decls: std::string = {};
    var gets: std::string = {};
    var passes: std::string = {};
    var afters: std::string = {};
    var raises: std::string = {};
    val drop = this.lua_drop(info.ret, "r");
    for (k) in 0..info.params.len {
        val p = info.params.at(k);
        var a: lua_arg = {};
        val idx = unum(@cast<u64>(k + 1));
        val what = fmt2("\"argument #{} to '{}'\"", copy idx, S(info.c_name));
        val cname = fmt("p_{}", S(p.name));
        try this.lua_arg_of(p.ty, idx.as_str(), cname.as_str(), what.as_str(), &a);
        decls.append(fmt("    {}\n", copy a.decl).as_str());
        gets.append(fmt("    {}\n", copy a.get).as_str());
        if (passes.len() > 0) {
            passes.append(", ");
        }
        passes.append(a.pass.as_str());
        if (a.after.len() > 0) {
            afters.append(fmt("    {}\n", copy a.after).as_str());
        }
        if (a.cb.len() > 0) {
            raises.append(fmt3("    if ({}.err != LUA_NOREF) {{ {}vl_rethrow(L, {}.err); }}\n", copy a.cb, copy drop, copy a.cb).as_str());
        }
    }
    out.append(fmt("\nstatic int vl_f_{}(lua_State *L) {{\n", S(info.c_name)).as_str());
    out.append(decls.as_str());
    out.append(gets.as_str());
    val call = fmt2("{}({})", S(info.c_name), move passes);
    if (info.ret == VOID) {
        out.append(fmt("    {};\n", move call).as_str());
    } else {
        out.append(fmt2("    {}r = {};\n", spaced(this.c_prim(info.ret, false)), move call).as_str());
    }
    // a callback's error first, then the result (or its error), then what Volt changed comes back
    out.append(raises.as_str());
    val res = try this.lua_result(info.ret, "r");
    if (res.len() > 0) {
        out.append(fmt("    {}\n", copy res).as_str());
    }
    out.append(afters.as_str());
    out.append(fmt("    return {};\n}\n", unum(@cast<u64>(this.lua_count(info.ret)))).as_str());
    return;
}

attach fn lua_text(this: bind&) -> compile_error!std::string {
    val ents = this.entries();
    val p = this.pkg;
    var out = fmt("// {}: generated by voltc bindings; a Lua (5.4 or later) C module for the Volt package.\n", S(p));
    out.append(fmt3("// Build it against the library and Lua's headers:\n//   cc -shared -fPIC {}_lua.c -L. -l{} -o {}.so\n", S(p), S(p), S(p)).as_str());
    out.append(fmt("// then require \"{}\". An error is raised as a table with its name and code.\n#include <lua.h>\n#include <lauxlib.h>\n#include <limits.h>\n#include <stdlib.h>\n#include <string.h>\n\n", S(p)).as_str());
    out.append(this.c_text().as_str());
    out.append("\n// ---------- conversions: each raises an error naming what didn't fit ----------\n\n");
    out.append("static inline lua_Integer vl_int(lua_State *L, int idx, lua_Integer lo, lua_Integer hi, const char *what) {\n    int ok = 0;\n    lua_Integer v = lua_tointegerx(L, idx, &ok);\n    if (!ok) {\n        luaL_error(L, \"%s: expected an integer, got %s\", what, luaL_typename(L, idx));\n    }\n    if (v < lo || v > hi) {\n        luaL_error(L, \"%s: %I doesn't fit\", what, v);\n    }\n    return v;\n}\n\n");
    out.append("static inline lua_Number vl_num(lua_State *L, int idx, const char *what) {\n    int ok = 0;\n    lua_Number v = lua_tonumberx(L, idx, &ok);\n    if (!ok) {\n        luaL_error(L, \"%s: expected a number, got %s\", what, luaL_typename(L, idx));\n    }\n    return v;\n}\n\n");
    out.append("static inline bool vl_bool(lua_State *L, int idx, const char *what) {\n    if (!lua_isboolean(L, idx)) {\n        luaL_error(L, \"%s: expected a boolean, got %s\", what, luaL_typename(L, idx));\n    }\n    return lua_toboolean(L, idx);\n}\n\n");
    out.append("// a string's bytes (Lua keeps them while the string is on the stack)\nstatic inline const char *vl_str(lua_State *L, int idx, size_t *len, const char *what) {\n    if (lua_type(L, idx) != LUA_TSTRING) {\n        luaL_error(L, \"%s: expected a string, got %s\", what, luaL_typename(L, idx));\n    }\n    return lua_tolstring(L, idx, len);\n}\n\n");
    out.append("// a sequence's length\nstatic inline size_t vl_seq(lua_State *L, int idx, const char *what) {\n    if (!lua_istable(L, idx)) {\n        luaL_error(L, \"%s: expected a table, got %s\", what, luaL_typename(L, idx));\n    }\n    return (size_t)luaL_len(L, idx);\n}\n\n");
    out.append("static inline void *vl_pointer(lua_State *L, int idx, const char *what) {\n    if (!lua_islightuserdata(L, idx)) {\n        luaL_error(L, \"%s: expected a pointer from this library, got %s\", what, luaL_typename(L, idx));\n    }\n    return lua_touserdata(L, idx);\n}\n");
    if (this.texts.len > 0) {
        out.append("\n// owned text: a Lua string, and the text freed\nstatic inline void vl_push_text(lua_State *L, volt_text t) {\n    lua_pushlstring(L, (const char *)t.ptr, t.len);\n    volt_text_free(t);\n}\n");
    }
    if (this.closures.len > 0) {
        out.append("\n// raises again what a callback raised\nstatic inline int vl_rethrow(lua_State *L, int ref) {\n    lua_rawgeti(L, LUA_REGISTRYINDEX, ref);\n    luaL_unref(L, LUA_REGISTRYINDEX, ref);\n    return lua_error(L);\n}\n");
    }
    // errors: a table {name = NAME, code = N} whose tostring is its name
    out.append("\nstatic inline const char *vl_error_name(uint32_t code) {\n    switch (code) {\n");
    for (c&) in this.all_codes().items() {
        out.append(fmt2("    case {}u: return \"{}\";\n", num(c.code), S(c.name)).as_str());
    }
    out.append(fmt("    }\n    return \"ERROR\";\n}\n\n// raises the error object for a Volt error code\nstatic inline int vl_raise(lua_State *L, uint32_t code) {\n    lua_createtable(L, 0, 2);\n    lua_pushstring(L, vl_error_name(code));\n    lua_setfield(L, -2, \"name\");\n    lua_pushinteger(L, (lua_Integer)code);\n    lua_setfield(L, -2, \"code\");\n    luaL_setmetatable(L, \"{}.error\");\n    return lua_error(L);\n}\n", S(p)).as_str());
    out.append("\nstatic int vl_error_tostring(lua_State *L) {\n    lua_getfield(L, 1, \"name\");\n    return 1;\n}\n");
    // structs: to and from tables
    for (s&) in this.structs.items() {
        if (!this.node_simple(this.c.t.intern(tyk::STRUCT(*s)))) {
            continue;
        }
        val sn = this.node_sname(*s);
        val cn = this.c_named(this.c.si(*s).name, false);
        out.append(fmt2("\nstatic inline void vl_get_{}(lua_State *L, int idx, {} *out, const char *what) {{\n    idx = lua_absindex(L, idx);\n    if (!lua_istable(L, idx)) {{\n", copy sn, copy cn).as_str());
        out.append("        luaL_error(L, \"%s: expected a table, got %s\", what, luaL_typename(L, idx));\n    }\n");
        for (f&) in this.c.si(*s).fields.items() {
            val fw = fmt2("\"field {} of {}\"", S(f.name), copy sn);
            out.append(fmt2("    lua_getfield(L, idx, \"{}\");\n    {}\n    lua_pop(L, 1);\n", S(f.name), this.lua_get(f.ty, "-1", fmt("out->{}", S(f.name)).as_str(), fw.as_str())).as_str());
        }
        out.append("}\n");
        out.append(fmt2("\nstatic inline void vl_set_{}(lua_State *L, int idx, const {} *in) {{\n    idx = lua_absindex(L, idx);\n", copy sn, copy cn).as_str());
        for (f&) in this.c.si(*s).fields.items() {
            out.append(fmt2("    {}\n    lua_setfield(L, idx, \"{}\");\n", this.lua_push(f.ty, fmt("in->{}", S(f.name)).as_str()), S(f.name)).as_str());
        }
        out.append("}\n");
        out.append(fmt3("\nstatic inline void vl_new_{}(lua_State *L, const {} *in) {{\n    lua_newtable(L);\n    vl_set_{}(L, -1, in);\n}}\n", copy sn, copy cn, copy sn).as_str());
    }
    // callbacks: the C function a Volt closure parameter calls; it calls the Lua function (and
    // converts its result) in a protected call, vl_runN
    if (this.closures.len > 0) {
        out.append("\n// a Lua function passed for a callback: its place on the stack during the call, and the\n// registry reference of the first error it raised (later calls are skipped)\nstruct vl_cb {\n    lua_State *L;\n    int fn;\n    int err;\n};\n");
    }
    for (i) in 0..this.closures.len {
        match (*this.c.t.get(*this.closures.at(i))) {
            .FN_VAL(ps&, r) => {
                val n = unum(@cast<u64>(i));
                out.append(fmt("\n// 1: the Lua function, 2: where its result goes, then its arguments\nstatic int vl_run{}(lua_State *L) {{\n", copy n).as_str());
                if (r != VOID) {
                    if (!this.node_simple(r)) {
                        return fail(NO_SPAN, fmt("a callback returning {} can't call Lua", this.c.ty_name(r)));
                    }
                    out.append(fmt("    {}*out = lua_touserdata(L, 2);\n    lua_remove(L, 2);\n    lua_call(L, lua_gettop(L) - 1, 1);\n", spaced(this.c_prim(r, false))).as_str());
                    out.append(fmt("    {}\n    return 0;\n}\n", this.lua_get(r, "-1", "*out", "\"the callback's result\"")).as_str());
                } else {
                    out.append("    lua_remove(L, 2);\n    lua_call(L, lua_gettop(L) - 1, 0);\n    return 0;\n}\n");
                }
                var params = S("void *user");
                for (k) in 0..ps.len {
                    params.append(fmt2(", {}a{}", spaced(this.c_prim(*ps.at(k), false)), unum(@cast<u64>(k))).as_str());
                }
                out.append(fmt3("\nstatic {}vl_cb{}({}) {{\n    struct vl_cb *c = user;\n    lua_State *L = c->L;\n", spaced(this.c_prim(r, false)), copy n, move params).as_str());
                var ret = S("return;");
                var place = S("NULL");
                if (r != VOID) {
                    out.append(fmt("    {}out;\n    memset(&out, 0, sizeof out);\n", spaced(this.c_prim(r, false))).as_str());
                    ret = S("return out;");
                    place = S("&out");
                }
                out.append(fmt2("    if (c->err != LUA_NOREF) {{\n        {}\n    }}\n    lua_pushcfunction(L, vl_run{});\n    lua_pushvalue(L, c->fn);\n", copy ret, copy n).as_str());
                out.append(fmt("    lua_pushlightuserdata(L, {});\n", move place).as_str());
                for (k) in 0..ps.len {
                    val ak = fmt("a{}", unum(@cast<u64>(k)));
                    match (this.shape_of(*ps.at(k)) ?? shape::VOID) {
                        .STR => { out.append(fmt2("    lua_pushlstring(L, (const char *){}.ptr, {}.len);\n", copy ak, copy ak).as_str()); },
                        default => {
                            if (!this.node_simple(*ps.at(k))) {
                                return fail(NO_SPAN, fmt("a callback taking {} can't call Lua", this.c.ty_name(*ps.at(k))));
                            }
                            out.append(fmt("    {}\n", this.lua_push(*ps.at(k), ak.as_str())).as_str());
                        },
                    }
                }
                out.append(fmt2("    if (lua_pcall(L, {}, 0, 0) != LUA_OK) {{\n        c->err = luaL_ref(L, LUA_REGISTRYINDEX);\n    }}\n    {}\n}}\n", unum(@cast<u64>(ps.len + 2)), move ret).as_str());
            },
            default => {},
        }
    }
    // classes: a full userdata holding the handle (NULL once closed)
    for (s&) in this.handles.items() {
        val sn = this.node_sname(*s);
        val cn = this.handle_c(*s, false);
        val mt = fmt2("{}.{}", S(p), copy sn);
        out.append(fmt3("\n// export struct {}\nstatic inline {}vl_check_{}(lua_State *L, int idx, const char *what) {{\n", S(this.c.si(*s).name), spaced(copy cn), copy sn).as_str());
        out.append(fmt3("    {}*h = luaL_testudata(L, idx, \"{}\");\n    if (!h) {{\n        luaL_error(L, \"%s: expected a {}, got %s\", what, luaL_typename(L, idx));\n    }}\n", spaced(copy cn), copy mt, copy sn).as_str());
        out.append(fmt("    if (!*h) {{\n        luaL_error(L, \"%s: this {} is closed\", what);\n    }}\n    return *h;\n}}\n", copy sn).as_str());
        out.append(fmt3("\nstatic inline void vl_wrap_{}(lua_State *L, {}h) {{\n    {}*u = lua_newuserdatauv(L, sizeof h, 0);\n", copy sn, spaced(copy cn), spaced(copy cn)).as_str());
        out.append(fmt("    *u = h;\n    luaL_setmetatable(L, \"{}\");\n}\n", copy mt).as_str());
        out.append(fmt3("\n// close, __close and __gc: frees the handle (once)\nstatic int vl_close_{}(lua_State *L) {{\n    {}*h = luaL_checkudata(L, 1, \"{}\");\n", copy sn, spaced(copy cn), copy mt).as_str());
        out.append(fmt("    if (*h) {{\n        {}(*h);\n        *h = NULL;\n    }}\n    return 0;\n}}\n", this.free_name(*s)).as_str());
    }
    // the functions
    for (e&) in ents.items() {
        if (e.free_of == null) {
            try this.lua_fn(e.f, &out);
        }
    }
    // the module: its functions, enums (tables of numbers), error sets (tables of names) and classes
    out.append(fmt("\nLUAMOD_API int luaopen_{}(lua_State *L) {{\n", S(p)).as_str());
    out.append(fmt("    luaL_newmetatable(L, \"{}.error\");\n    lua_pushcfunction(L, vl_error_tostring);\n    lua_setfield(L, -2, \"__tostring\");\n    lua_pop(L, 1);\n    lua_newtable(L);\n", S(p)).as_str());
    for (e&) in ents.items() {
        if (e.free_of != null || this.class_of(e.f) != null) {
            continue;
        }
        val n = S(this.c.fi(e.f).c_name);
        out.append(fmt2("    lua_pushcfunction(L, vl_f_{});\n    lua_setfield(L, -2, \"{}\");\n", copy n, copy n).as_str());
    }
    for (en&) in this.enums.items() {
        val info = this.c.ei(*en);
        out.append("    lua_newtable(L);\n");
        for (i) in 0..info.names.len {
            out.append(fmt2("    lua_pushinteger(L, {});\n    lua_setfield(L, -2, \"{}\");\n", num(*info.values.at(i)), S(*info.names.at(i))).as_str());
        }
        out.append(fmt("    lua_setfield(L, -2, \"{}\");\n", this.local(info.name)).as_str());
    }
    for (et&) in this.codes.items() {
        match (*this.c.t.get(*et)) {
            .ENUM(e) => {
                val info = this.c.ei(e);
                out.append("    lua_newtable(L);\n");
                for (i) in 0..info.names.len {
                    out.append(fmt2("    lua_pushstring(L, \"{}\");\n    lua_setfield(L, -2, \"{}\");\n", S(*info.names.at(i)), S(*info.names.at(i))).as_str());
                }
                out.append(fmt("    lua_setfield(L, -2, \"{}\");\n", this.local(info.name)).as_str());
            },
            default => {},
        }
    }
    for (s&) in this.handles.items() {
        val sn = this.node_sname(*s);
        // its metatable (__index: the methods) and its table (what makes one: counter.new(...))
        out.append(fmt2("    luaL_newmetatable(L, \"{}.{}\");\n    lua_newtable(L);\n", S(p), copy sn).as_str());
        out.append(fmt("    lua_pushcfunction(L, vl_close_{});\n    lua_setfield(L, -2, \"close\");\n", copy sn).as_str());
        var statics: std::string = {};
        for (e&) in ents.items() {
            if (e.free_of != null) {
                continue;
            }
            val m = this.member_of(e.f, *s) ?? continue;
            val line = fmt2("    lua_pushcfunction(L, vl_f_{});\n    lua_setfield(L, -2, \"{}\");\n", S(this.c.fi(e.f).c_name), S(m));
            if (this.node_is_method(e.f, *s)) {
                out.append(line.as_str());
            } else {
                statics.append(line.as_str());
            }
        }
        out.append(fmt2("    lua_setfield(L, -2, \"__index\");\n    lua_pushcfunction(L, vl_close_{});\n    lua_setfield(L, -2, \"__gc\");\n    lua_pushcfunction(L, vl_close_{});\n", copy sn, copy sn).as_str());
        out.append("    lua_setfield(L, -2, \"__close\");\n    lua_pop(L, 1);\n    lua_newtable(L);\n");
        out.append(statics.as_str());
        out.append(fmt("    lua_setfield(L, -2, \"{}\");\n", copy sn).as_str());
    }
    out.append("    return 1;\n}\n");
    return out;
}

// ---------- Dart (dart:ffi, Dart 3.4 or later) ----------

fn dart_keyword(s: str) -> bool {
    val words: str[] = { "assert", "await", "break", "case", "catch", "class", "const", "continue", "default", "do", "else", "enum", "extends", "false", "final", "finally", "for", "if", "in", "is", "new", "null", "rethrow", "return", "super", "switch", "this", "throw", "true", "try", "var", "void", "while", "with", "yield" };
    for (w) in words {
        if (w == s) {
            return true;
        }
    }
    return false;
}

fn dart_ident(s: str) -> std::string {
    if (dart_keyword(s)) {
        return fmt("{}_", S(s));
    }
    return S(s);
}

fn dart_int(k: int_ty) -> str {
    match (k) {
        .I8 => { return "Int8"; },
        .I16 => { return "Int16"; },
        .I32 => { return "Int32"; },
        .I64 => { return "Int64"; },
        .U8 => { return "Uint8"; },
        .U16 => { return "Uint16"; },
        .U32 => { return "Uint32"; },
        .U64 => { return "Uint64"; },
        .ISIZE => { return "IntPtr"; },
        .USIZE => { return "Size"; },
        default => { return "Int64"; },
    }
}

// a type as dart:ffi declares it in a native signature (Int32, Double, a struct class, a Pointer)
attach fn dart_native(this: bind&, t: u32) -> std::string {
    match (this.shape_of(t) ?? shape::VOID) {
        .VOID => { return S("Void"); },
        .BOOL => { return S("Bool"); },
        .INT(k) => { return S(dart_int(k)); },
        .FLOAT(b) => {
            if (b == 32) {
                return S("Float");
            }
            return S("Double");
        },
        .CSTR => { return S("Pointer<Char>"); },
        .STR => { return S("VoltStr"); },
        .TEXT(x) => { return S("VoltText"); },
        .PTR(x) => {
            if (x == VOID) {
                return S("Pointer<Void>");
            }
            match (this.shape_of(x) ?? shape::VOID) {
                .HANDLE(s) => { return S("Pointer<Void>"); },
                .ARRAY(e, n) => { return S("Pointer<Void>"); },
                .FN(i) => { return S("Pointer<Void>"); },
                default => {},
            }
            return fmt("Pointer<{}>", this.dart_native(x));
        },
        .HANDLE(s) => { return S("Pointer<Void>"); },
        .STRUCT(s) => { return this.local(this.c.si(s).name); },
        .ENUM(e) => { return S(dart_int(this.c.ei(e).tag)); },
        .CODE => { return S("Uint32"); },
        .RESULT(e, x) => { return this.result_name(t); },
        .ARRAY(elem, n) => { return S("Pointer<Void>"); },
        .SLICE(x) => { return this.made_name("slice", x, true); },
        .OPT(x) => { return this.made_name("opt", x, true); },
        .FN(i) => { return S("Pointer<Void>"); },
        .CLOSURE(i) => { return fmt("Pointer<NativeFunction<{}>>", this.dart_cb_sig(t, true)); },
        .TRAIT(i) => { return S("void"); }, // only C, C++, Rust and Zig take traits (bind.wide)
    }
}

// the Dart type dart:ffi gives a native type (int, double, bool, or the same class)
attach fn dart_raw(this: bind&, t: u32) -> std::string {
    match (this.shape_of(t) ?? shape::VOID) {
        .VOID => { return S("void"); },
        .BOOL => { return S("bool"); },
        .INT(k) => { return S("int"); },
        .FLOAT(b) => { return S("double"); },
        .ENUM(e) => { return S("int"); },
        .CODE => { return S("int"); },
        default => { return this.dart_native(t); },
    }
}

// a closure's C function type: R Function(Pointer<Void>, A...), native or Dart
attach fn dart_cb_sig(this: bind&, t: u32, native: bool) -> std::string {
    match (*this.c.t.get(t)) {
        .FN_VAL(ps&, r) => {
            var args = S("Pointer<Void>");
            for (p&) in ps.items() {
                args.append(", ");
                if (native) {
                    args.append(this.dart_native(*p).as_str());
                } else {
                    args.append(this.dart_raw(*p).as_str());
                }
            }
            if (native) {
                return fmt2("{} Function({})", this.dart_native(r), move args);
            }
            return fmt2("{} Function({})", this.dart_raw(r), move args);
        },
        default => { return S("Void Function()"); },
    }
}

// a type as the Dart API shows it
attach fn dart_ty(this: bind&, t: u32) -> std::string {
    val h = this.lent_handle(t);
    if (h) {
        return this.local(this.c.si(h).name);
    }
    match (this.shape_of(t) ?? shape::VOID) {
        .CSTR => { return S("String?"); },
        .STR => { return S("String"); },
        .TEXT(x) => { return S("String"); },
        .ENUM(e) => { return this.local(this.c.ei(e).name); },
        .PTR(x) => {
            val s = this.ref_struct(t);
            if (s) {
                var n = this.local(this.c.si(s).name);
                if (this.nullable_ptr(t)) {
                    n.push('?');
                }
                return n;
            }
            return this.dart_native(t);
        },
        .HANDLE(s) => { return this.local(this.c.si(s).name); },
        .SLICE(x) => { return fmt("List<{}>", this.dart_ty(x)); },
        .OPT(x) => { return fmt("{}?", this.dart_ty(x)); },
        .RESULT(e, x) => { return this.dart_ty(x); },
        .CLOSURE(i) => {
            match (*this.c.t.get(t)) {
                .FN_VAL(ps&, r) => {
                    var args: std::string = {};
                    for (p&) in ps.items() {
                        if (args.len() > 0) {
                            args.append(", ");
                        }
                        args.append(this.dart_ty(*p).as_str());
                    }
                    return fmt2("{} Function({})", this.dart_ty(r), move args);
                },
                default => { return S("Function"); },
            }
        },
        default => { return this.dart_raw(t); },
    }
}

// an expression turning API value v (of type t) into what the C function takes, for the simple
// types (numbers, bool, enums, structs)
attach fn dart_in(this: bind&, t: u32, v: str) -> std::string {
    match (this.shape_of(t) ?? shape::VOID) {
        .ENUM(e) => { return fmt("{}.value", S(v)); },
        default => { return S(v); },
    }
}

// an expression turning C value r (of type t) into the API's value, for the simple types and str
attach fn dart_out(this: bind&, t: u32, r: str) -> std::string {
    match (this.shape_of(t) ?? shape::VOID) {
        .ENUM(e) => { return fmt2("{}.of({})", this.local(this.c.ei(e).name), S(r)); },
        .STR => { return fmt("_text({})", S(r)); },
        default => { return S(r); },
    }
}

// one parameter of a wrapper: its declaration, what the call passes, the statements before the
// try block (outer: a callback's NativeCallable), before the call (pre), after it (after: copying
// back), in the finally block (fin), and a callback's rethrow
struct dart_arg {
    decl: std::string = {};
    pass: std::string = {};
    outer: std::string = {};
    pre: std::string = {};
    after: std::string = {};
    fin: std::string = {};
    raise: std::string = {};
    err: std::string = {};  // a callback's variable holding what it threw
    held: bool = false; // it allocates native memory (freed in the finally block)
}

attach fn dart_arg_of(this: bind&, t: u32, name0: str, a: dart_arg&) -> compile_error!void {
    val nm = dart_ident(name0);
    val n = nm.as_str();
    a.decl = fmt2("{} {}", this.dart_ty(t), S(n));
    val h = this.lent_handle(t);
    if (h) {
        a.pass = fmt("{}._handle()", S(n));
        return;
    }
    match (this.shape_of(t) ?? shape::VOID) {
        .STR => {
            a.pass = fmt("_str({}, held$)", S(n));
            a.held = true;
        },
        .CSTR => {
            a.pass = fmt("_cstr({}, held$)", S(n));
            a.held = true;
        },
        .PTR(x) => {
            val s = this.ref_struct(t);
            if (s) {
                    // a copy goes in, and what Volt changed comes back
                    val sn = this.local(this.c.si(s).name);
                    a.held = true;
                    if (this.nullable_ptr(t)) {
                        a.pre = fmt4("final {}$p = {} == null ? nullptr : _alloc<{}>(sizeOf<{}>(), held$);\n", S(n), S(n), copy sn, copy sn);
                        a.pre.append(fmt2("if ({} != null) {{\n  {}$p.ref = ", S(n), S(n)).as_str());
                        a.pre.append(fmt("{};\n}\n", S(n)).as_str());
                        a.after = fmt2("if ({} != null) {{\n  {}.copyFrom(", S(n), S(n));
                        a.after.append(fmt("{}$p.ref);\n}\n", S(n)).as_str());
                    } else {
                        a.pre = fmt3("final {}$p = _alloc<{}>(sizeOf<{}>(), held$);\n", S(n), copy sn, copy sn);
                        a.pre.append(fmt2("{}$p.ref = {};\n", S(n), S(n)).as_str());
                        a.after = fmt2("{}.copyFrom({}$p.ref);\n", S(n), S(n));
                    }
                    a.pass = fmt("{}$p", S(n));
                    return;
            }
            a.pass = S(n);
        },
        .SLICE(x) => {
            if (!this.simple_value(x)) {
                return fail(NO_SPAN, fmt("a slice of {} can't come from Dart (numbers, bool, enums and structs of those can)", this.c.ty_name(x)));
            }
            val en = this.dart_native(x);
            a.held = true;
            a.pre = fmt4("final {}$p = _alloc<{}>(sizeOf<{}>() * {}.length, held$);\n", S(n), copy en, copy en, S(n));
            a.pre.append(fmt3("final {}$s = Struct.create<{}>()\n  ..ptr = {}$p\n", S(n), this.made_name("slice", x, true), S(n)).as_str());
            a.pre.append(fmt2("  ..len = {}.length;\nfor (var i = 0; i < {}.length; i++) {{\n", S(n), S(n)).as_str());
            match (this.shape_of(x) ?? shape::VOID) {
                .STRUCT(s) => {
                    a.pre.append(fmt2("  ({}$p + i).ref = {}[i];\n}\n", S(n), S(n)).as_str());
                    // what Volt wrote into the elements comes back
                    a.after = fmt3("for (var i = 0; i < {}.length; i++) {{\n  {}[i].copyFrom(({}$p + i).ref);\n}}\n", S(n), S(n), S(n));
                },
                default => {
                    a.pre.append(fmt2("  {}$p[i] = {};\n}\n", S(n), this.dart_in(x, fmt("{}[i]", S(n)).as_str())).as_str());
                    // copied back where Volt changed it (an unmodifiable list it didn't change is fine)
                    val back = this.dart_out(x, fmt("{}$p[i]", S(n)).as_str());
                    a.after = fmt4("for (var i = 0; i < {}.length; i++) {{\n  final v = {};\n  if ({}[i] != v) {{\n    {}[i] = v;\n  }}\n}}\n", S(n), copy back, S(n), S(n));
                },
            }
            a.pass = fmt("{}$s", S(n));
        },
        .OPT(x) => {
            if (!this.simple_value(x)) {
                return fail(NO_SPAN, fmt("an optional {} can't come from Dart", this.c.ty_name(x)));
            }
            a.pre = fmt3("final {}$o = Struct.create<{}>()..has = {} != null;\n", S(n), this.made_name("opt", x, true), S(n));
            a.pre.append(fmt3("if ({} != null) {{\n  {}$o.value = {};\n}}\n", S(n), S(n), this.dart_in(x, n)).as_str());
            a.pass = fmt("{}$o", S(n));
        },
        .CLOSURE(i) => {
            match (*this.c.t.get(t)) {
                .FN_VAL(ps&, r) => {
                    // the Dart function, called through a NativeCallable; what it throws is kept,
                    // the later calls are skipped, and it's thrown again once the call is back
                    var params = S("Pointer<Void> u$");
                    var args: std::string = {};
                    for (k) in 0..ps.len {
                        val ak = fmt("a{}", unum(@cast<u64>(k)));
                        params.append(fmt2(", {} {}", this.dart_raw(*ps.at(k)), copy ak).as_str());
                        if (k > 0) {
                            args.append(", ");
                        }
                        match (this.shape_of(*ps.at(k)) ?? shape::VOID) {
                            .STR => {},
                            default => {
                                if (!this.simple_value(*ps.at(k))) {
                                    return fail(NO_SPAN, fmt("a callback taking {} can't call Dart", this.c.ty_name(*ps.at(k))));
                                }
                            },
                        }
                        args.append(this.dart_out(*ps.at(k), ak.as_str()).as_str());
                    }
                    var dflt: std::string = {};
                    match (this.shape_of(r) ?? shape::VOID) {
                        .VOID => {},
                        .BOOL => { dflt = S("false"); },
                        .FLOAT(b) => { dflt = S("0.0"); },
                        .INT(k) => { dflt = S("0"); },
                        .ENUM(e) => { dflt = S("0"); },
                        .CODE => { dflt = S("0"); },
                        default => { return fail(NO_SPAN, fmt("a callback returning {} can't call Dart", this.c.ty_name(r))); },
                    }
                    a.outer = fmt2("Object? {}$err;\nStackTrace? {}$st;\n", S(n), S(n));
                    a.outer.append(fmt3("final {}$cb = NativeCallable<{}>.isolateLocal(({}) {{\n", S(n), this.dart_cb_sig(t, true), move params).as_str());
                    var ret = S("return;");
                    if (dflt.len() > 0) {
                        ret = fmt("return {};", copy dflt);
                    }
                    a.outer.append(fmt2("  if ({}$err != null) {{\n    {}\n  }}\n  try {{\n", S(n), copy ret).as_str());
                    val call = fmt2("{}({})", S(n), move args);
                    if (dflt.len() > 0) {
                        a.outer.append(fmt("    return {};\n", this.dart_in(r, call.as_str())).as_str());
                    } else {
                        a.outer.append(fmt("    {};\n", copy call).as_str());
                    }
                    a.outer.append(fmt3("  } catch (e, st) {{\n    {}$err = e;\n    {}$st = st;\n", S(n), S(n), S("")).as_str());
                    if (dflt.len() > 0) {
                        a.outer.append(fmt2("    {}\n  }}\n}}, exceptionalReturn: {});\n", copy ret, copy dflt).as_str());
                    } else {
                        a.outer.append("  }\n});\n");
                    }
                    a.pass = fmt("{}$cb.nativeFunction, nullptr", S(n));
                    a.fin = fmt("{}$cb.close();\n", S(n));
                    a.err = fmt("{}$err", S(n));
                    a.raise = fmt3("if ({}$err != null) {{\n  Error.throwWithStackTrace({}$err!, {}$st!);\n}}\n", S(n), S(n), S(n));
                },
                default => {},
            }
        },
        default => { a.pass = this.dart_in(t, n); },
    }
    return;
}

// statements turning C result r (of type t) into the API's value v$ (or throwing its error)
attach fn dart_result(this: bind&, t: u32, r: str) -> compile_error!std::string {
    match (this.shape_of(t) ?? shape::VOID) {
        .VOID => { return {}; },
        .CSTR => { return fmt("final v$ = _fromCstr({});\n", S(r)); },
        .TEXT(x) => { return fmt("final v$ = _take({});\n", S(r)); },
        .HANDLE(s) => { return fmt2("final v$ = {}._({});\n", this.local(this.c.si(s).name), S(r)); },
        .OPT(x) => {
            if (!this.simple_value(x)) {
                return fail(NO_SPAN, fmt("an optional {} can't go to Dart", this.c.ty_name(x)));
            }
            return fmt3("final v$ = {}.has ? {} : null;\n", S(r), this.dart_out(x, fmt("{}.value", S(r)).as_str()), S(""));
        },
        .SLICE(x) => {
            match (this.shape_of(x) ?? shape::VOID) {
                .STRUCT(s) => {
                    // copies: the elements belong to the library
                    return fmt3("final v$ = List.generate({}.len, (i) => Struct.create<{}>()..copyFrom(({}.ptr + i).ref));\n", S(r), this.local(this.c.si(s).name), S(r));
                },
                default => {},
            }
            if (!this.simple_value(x)) {
                return fail(NO_SPAN, fmt("a slice of {} can't go to Dart", this.c.ty_name(x)));
            }
            return fmt2("final v$ = List.generate({}.len, (i) => {});\n", S(r), this.dart_out(x, fmt("{}.ptr[i]", S(r)).as_str()));
        },
        .RESULT(e, x) => {
            var out = fmt("if ({}.error != 0) {{\n  throw VoltError.of(", S(r));
            out.append(fmt("{}.error);\n}\n", S(r)).as_str());
            if (x != VOID) {
                out.append((try this.dart_result(x, fmt("{}.value", S(r)).as_str())).as_str());
            }
            return out;
        },
        default => { return fmt("final v$ = {};\n", this.dart_out(t, r)); },
    }
}

// what frees owned C result r (of type t) when a callback's error is thrown instead
attach fn dart_drop(this: bind&, t: u32, r: str) -> std::string {
    match (this.shape_of(t) ?? shape::VOID) {
        .TEXT(x) => { return fmt("_take({});\n", S(r)); },
        .HANDLE(s) => { return fmt2("Native.{}({});\n", this.free_name(s), S(r)); },
        .RESULT(e, x) => {
            val inner = this.dart_drop(x, fmt("{}.value", S(r)).as_str());
            if (inner.len() == 0) {
                return {};
            }
            return fmt2("if ({}.error == 0) {{\n{}}}\n", S(r), indent_n(inner.as_str(), 2));
        },
        default => { return {}; },
    }
}

// does a result of type t give a value (not void, not an E!void)?
attach fn dart_returns(this: bind&, t: u32) -> bool {
    match (this.shape_of(t) ?? shape::VOID) {
        .VOID => { return false; },
        .RESULT(e, x) => { return x != VOID; },
        default => { return true; },
    }
}

attach fn dart_doc(this: bind&, f: u32, ind: str) -> std::string {
    val sp = this.c.dl(this.c.fi(f).decl).item.span;
    val d = doc_above(this.c.files.at(sp.file).text, @cast<usize>(sp.lo));
    if (d.len() == 0) {
        return {};
    }
    return fmt2("{}/// {}\n", S(ind), move d);
}

// a wrapper: its signature (the parameters from first on; self passes an instance's handle) and body
attach fn dart_fn(this: bind&, f: u32, first: usize, head: str, ind: str) -> compile_error!std::string {
    val info = this.c.fi(f);
    var decls: std::string = {};
    var passes: std::string = {};
    var outer: std::string = {};
    var pre: std::string = {};
    var after: std::string = {};
    var fin: std::string = {};
    var raise: std::string = {};
    var failed: std::string = {};
    var held = false;
    if (first == 1) {
        passes = S("_handle()");
    }
    for (k) in first..info.params.len {
        val p = info.params.at(k);
        var a: dart_arg = {};
        try this.dart_arg_of(p.ty, p.name, &a);
        if (decls.len() > 0) {
            decls.append(", ");
        }
        decls.append(a.decl.as_str());
        if (passes.len() > 0) {
            passes.append(", ");
        }
        passes.append(a.pass.as_str());
        outer.append(a.outer.as_str());
        pre.append(a.pre.as_str());
        after.append(a.after.as_str());
        fin.append(a.fin.as_str());
        raise.append(a.raise.as_str());
        if (a.err.len() > 0) {
            if (failed.len() > 0) {
                failed.append(" || ");
            }
            failed.append(fmt("{} != null", copy a.err).as_str());
        }
        held = held || a.held;
    }
    var body: std::string = {};
    if (held) {
        body.append("final held$ = <Pointer<Void>>[];\n");
    }
    body.append(outer.as_str());
    var inner = move pre;
    if (info.ret == VOID) {
        inner.append(fmt2("Native.{}({});\n", S(info.c_name), move passes).as_str());
    } else {
        inner.append(fmt2("final r$ = Native.{}({});\n", S(info.c_name), move passes).as_str());
    }
    // a callback's error first (an owned result freed), then the result's, then what Volt changed
    // comes back
    if (raise.len() > 0) {
        val drop = this.dart_drop(info.ret, "r$");
        if (drop.len() > 0) {
            inner.append(fmt("if ({}) {{\n", copy failed).as_str());
            inner.append(indent_n(drop.as_str(), 2).as_str());
            inner.append("}\n");
        }
    }
    inner.append(raise.as_str());
    inner.append((try this.dart_result(info.ret, "r$")).as_str());
    inner.append(after.as_str());
    if (this.dart_returns(info.ret)) {
        inner.append("return v$;\n");
    }
    if (held) {
        fin.append("for (final p in held$) {\n  _free(p);\n}\n");
    }
    if (fin.len() > 0) {
        body.append("try {\n");
        body.append(indent_n(inner.as_str(), 2).as_str());
        body.append("} finally {\n");
        body.append(indent_n(fin.as_str(), 2).as_str());
        body.append("}\n");
    } else {
        body.append(inner.as_str());
    }
    var out = this.dart_doc(f, ind);
    out.append(fmt3("{}{}({}) {{\n", S(ind), S(head), move decls).as_str());
    out.append(indent_n(body.as_str(), ind.len + 2).as_str());
    out.append(fmt("{}}\n", S(ind)).as_str());
    return out;
}

// a struct field's declaration: its annotation (numbers, bool, arrays) and type
attach fn dart_field(this: bind&, t: u32, name: str) -> std::string {
    match (*this.c.t.get(t)) {
        .ARRAY(elem, n) => {
            var dims = unum(n);
            var multi = false;
            var e = elem;
            var arr = true;
            while (arr) {
                match (*this.c.t.get(e)) {
                    .ARRAY(e2, n2) => {
                        dims.append(", ");
                        dims.append(unum(n2).as_str());
                        multi = true;
                        e = e2;
                    },
                    default => { arr = false; },
                }
            }
            var ty = this.dart_native(e);
            var d = elem;
            var nest = true;
            while (nest) {
                match (*this.c.t.get(d)) {
                    .ARRAY(e2, n2) => {
                        ty = fmt("Array<{}>", move ty);
                        d = e2;
                    },
                    default => { nest = false; },
                }
            }
            if (multi) {
                return fmt3("  @Array.multi([{}])\n  external Array<{}> {};\n", move dims, move ty, S(name));
            }
            return fmt3("  @Array({})\n  external Array<{}> {};\n", move dims, move ty, S(name));
        },
        default => {},
    }
    match (this.shape_of(t) ?? shape::VOID) {
        .BOOL => { return fmt("  @Bool()\n  external bool {};\n", S(name)); },
        .INT(k) => { return fmt2("  @{}()\n  external int {};\n", S(dart_int(k)), S(name)); },
        .FLOAT(b) => { return fmt3("  @{}()\n  external double {};\n", this.dart_native(t), S(name), S("")); },
        .ENUM(e) => { return fmt2("  @{}()\n  external int {};\n", S(dart_int(this.c.ei(e).tag)), S(name)); },
        .CODE => { return fmt("  @Uint32()\n  external int {};\n", S(name)); },
        default => { return fmt2("  external {} {};\n", this.dart_native(t), S(name)); },
    }
}

// the statements copying field f of struct from into to (inside copyFrom)
attach fn dart_copy(this: bind&, t: u32, to: str, from: str, ind: str) -> std::string {
    match (*this.c.t.get(t)) {
        .ARRAY(elem, n) => {
            val i = fmt("i{}", unum(@cast<u64>(ind.len)));
            var out = fmt4("{}for (var {} = 0; {} < {}; ", S(ind), copy i, copy i, unum(n));
            out.append(fmt2("{}++) {{\n{}", copy i, this.dart_copy(elem, fmt2("{}[{}]", S(to), copy i).as_str(), fmt2("{}[{}]", S(from), copy i).as_str(), fmt("{}  ", S(ind)).as_str())).as_str());
            out.append(fmt("{}}\n", S(ind)).as_str());
            return out;
        },
        default => {},
    }
    match (this.shape_of(t) ?? shape::VOID) {
        .STRUCT(s) => { return fmt3("{}{}.copyFrom({});\n", S(ind), S(to), S(from)); },
        default => { return fmt3("{}{} = {};\n", S(ind), S(to), S(from)); },
    }
}

attach fn dart_text(this: bind&) -> compile_error!std::string {
    val ents = this.entries();
    val p = this.pkg;
    var out = fmt("// {}: generated by voltc bindings; the Volt package for Dart (dart:ffi, Dart 3.4 or later).\n", S(p));
    out.append(fmt3("// It loads lib{}.so (lib{}.dylib, {}.dll), or the library $VOLT_", S(p), S(p), S(p)).as_str());
    out.append(fmt("{}_LIB names. Errors are thrown\n// as VoltError, one subclass per error set; an export struct is a class with close().\n", upper(p)).as_str());
    out.append("// ignore_for_file: camel_case_types, non_constant_identifier_names, constant_identifier_names, unused_element\nimport 'dart:convert';\nimport 'dart:ffi';\nimport 'dart:io';\n\n");
    out.append(fmt3("final DynamicLibrary _lib = DynamicLibrary.open(Platform.environment['VOLT_{}_LIB'] ??\n    (Platform.isMacOS ? 'lib{}.dylib' : Platform.isWindows ? '{}.dll' : ", upper(p), S(p), S(p)).as_str());
    out.append(fmt("'lib{}.so'));\n", S(p)).as_str());
    // native memory for the arguments: C's malloc and free
    out.append("\nfinal DynamicLibrary _libc = Platform.isWindows ? DynamicLibrary.open('ucrtbase.dll') : DynamicLibrary.process();\nfinal _malloc = _libc.lookupFunction<Pointer<Void> Function(Size), Pointer<Void> Function(int)>('malloc');\nfinal _free = _libc.lookupFunction<Void Function(Pointer<Void>), void Function(Pointer<Void>)>('free');\n");
    out.append("\n// bytes freed after the call (with the others in held)\nPointer<T> _alloc<T extends NativeType>(int bytes, List<Pointer<Void>> held) {\n  final p = _malloc(bytes > 0 ? bytes : 1);\n  if (p == nullptr) {\n    throw StateError('out of memory');\n  }\n  held.add(p);\n  return p.cast<T>();\n}\n");
    out.append("\n/// a Volt str: UTF-8 bytes and a length\nfinal class VoltStr extends Struct {\n  external Pointer<Uint8> ptr;\n  @Size()\n  external int len;\n}\n");
    out.append("\nVoltStr _str(String s, List<Pointer<Void>> held) {\n  final b = utf8.encode(s);\n  final p = _alloc<Uint8>(b.length, held);\n  p.asTypedList(b.length).setAll(0, b);\n  return Struct.create<VoltStr>()\n    ..ptr = p\n    ..len = b.length;\n}\n\nString _text(VoltStr s) => s.len == 0 ? '' : utf8.decode(s.ptr.asTypedList(s.len));\n");
    out.append("\nPointer<Char> _cstr(String? s, List<Pointer<Void>> held) {\n  if (s == null) {\n    return nullptr;\n  }\n  final b = utf8.encode(s);\n  final p = _alloc<Uint8>(b.length + 1, held);\n  p.asTypedList(b.length + 1)\n    ..setAll(0, b)\n    ..[b.length] = 0;\n  return p.cast<Char>();\n}\n");
    out.append("\nString? _fromCstr(Pointer<Char> p) {\n  if (p == nullptr) {\n    return null;\n  }\n  final b = p.cast<Uint8>();\n  var n = 0;\n  while (b[n] != 0) {\n    n++;\n  }\n  return utf8.decode(b.asTypedList(n));\n}\n");
    if (this.texts.len > 0) {
        out.append("\n/// owned text a Volt function gave out (the wrappers copy it into a String and free it)\nfinal class VoltText extends Struct {\n  external Pointer<Uint8> ptr;\n  @Size()\n  external int len;\n  external Pointer<Void> owner;\n  external Pointer<NativeFunction<Void Function(Pointer<Void>)>> drop;\n}\n");
        out.append("\nString _take(VoltText t) {\n  final s = t.len == 0 ? '' : utf8.decode(t.ptr.asTypedList(t.len));\n  if (t.drop != nullptr) {\n    t.drop.asFunction<void Function(Pointer<Void>)>()(t.owner);\n  }\n  return s;\n}\n");
    }
    // errors: VoltError, and a subclass per error set holding its codes
    out.append("\n/// an error a Volt function returned: its code and name\nclass VoltError implements Exception {\n  final int code;\n  final String name;\n\n  VoltError(this.code, this.name);\n\n  static VoltError of(int code) {\n    switch (code) {\n");
    for (c&) in this.all_codes().items() {
        out.append(fmt3("      case {}:\n        return {}(code, '{}');\n", num(c.code), copy c.set, S(c.name)).as_str());
    }
    out.append("    }\n    return VoltError(code, 'error');\n  }\n\n  @override\n  String toString() => name;\n}\n");
    for (et&) in this.codes.items() {
        match (*this.c.t.get(*et)) {
            .ENUM(e) => {
                val info = this.c.ei(e);
                val n = this.local(info.name);
                out.append(fmt3("\n/// error set {}: thrown for its errors; its codes\nclass {} extends VoltError {{\n  {}(super.code, super.name);\n\n", S(info.name), copy n, copy n).as_str());
                for (i) in 0..info.names.len {
                    out.append(fmt2("  static const int {} = {};\n", S(*info.names.at(i)), num(*info.values.at(i))).as_str());
                }
                out.append("}\n");
            },
            default => {},
        }
    }
    for (e&) in this.enums.items() {
        val info = this.c.ei(*e);
        val n = this.local(info.name);
        out.append(fmt("\nenum {} {{\n", copy n).as_str());
        for (i) in 0..info.names.len {
            var sep = ",";
            if (i + 1 == info.names.len) {
                sep = ";";
            }
            out.append(fmt3("  {}({}){}\n", S(*info.names.at(i)), num(*info.values.at(i)), S(sep)).as_str());
        }
        out.append(fmt3("\n  const {}(this.value);\n  final int value;\n\n  static {} of(int v) => values.firstWhere((e) => e.value == v);\n}}\n", copy n, copy n, S("")).as_str());
    }
    for (s&) in this.structs.items() {
        val info = this.c.si(*s);
        val n = this.local(info.name);
        out.append(fmt("\nfinal class {} extends Struct {{\n", copy n).as_str());
        var named: std::string = {};
        var sets: std::string = {};
        var copies: std::string = {};
        for (f&) in info.fields.items() {
            val fname = dart_ident(f.name);
            out.append(this.dart_field(f.ty, fname.as_str()).as_str());
            copies.append(this.dart_copy(f.ty, fname.as_str(), fmt("from.{}", copy fname).as_str(), "    ").as_str());
            match (*this.c.t.get(f.ty)) {
                .ARRAY(e, k) => {},
                default => {
                    if (named.len() > 0) {
                        named.append(", ");
                    }
                    named.append(fmt2("required {} {}", this.dart_raw(f.ty), copy fname).as_str());
                    sets.append(fmt2("\n    ..{} = {}", copy fname, copy fname).as_str());
                },
            }
        }
        // of: a new one (in Dart memory), and copyFrom
        if (named.len() > 0) {
            named = fmt("{{{}}}", move named);
        }
        out.append(fmt3("\n  factory {}.of({}) => Struct.create<{}>()", copy n, move named, copy n).as_str());
        out.append(fmt("{};\n", move sets).as_str());
        out.append(fmt2("\n  void copyFrom({} from) {{\n{}  }}\n}}\n", copy n, move copies).as_str());
    }
    for (x&) in this.slices.items() {
        out.append(fmt2("\n/// a Volt slice: elements and how many\nfinal class {} extends Struct {{\n  external Pointer<{}> ptr;\n  @Size()\n  external int len;\n}}\n", this.made_name("slice", *x, true), this.dart_native(*x)).as_str());
    }
    for (x&) in this.opts.items() {
        out.append(fmt2("\n/// a Volt optional: has says whether value is there\nfinal class {} extends Struct {{\n{}  @Bool()\n  external bool has;\n}}\n", this.made_name("opt", *x, true), this.dart_field(*x, "value")).as_str());
    }
    for (rt&) in this.results.items() {
        match (*this.c.t.get(*rt)) {
            .ERR_UNION(e, x) => {
                out.append(fmt2("\n/// {}: error is 0, or the error's code\nfinal class {} extends Struct {{\n  @Uint32()\n  external int error;\n", this.c.ty_name(*rt), this.result_name(*rt)).as_str());
                if (x != VOID) {
                    out.append(this.dart_field(x, "value").as_str());
                }
                out.append("}\n");
            },
            default => {},
        }
    }
    // the C functions
    out.append("\n/// the C functions (the functions and classes below are easier to use)\nabstract final class Native {\n");
    for (e&) in ents.items() {
        var nps: std::string = {};
        var dps: std::string = {};
        var nret = S("Void");
        var dret = S("void");
        if (e.free_of != null) {
            nps = S("Pointer<Void>");
            dps = S("Pointer<Void>");
        } else {
            val f = this.c.fi(e.f);
            nret = this.dart_native(f.ret);
            dret = this.dart_raw(f.ret);
            for (q&) in f.params.items() {
                if (nps.len() > 0) {
                    nps.append(", ");
                    dps.append(", ");
                }
                nps.append(this.dart_native(q.ty).as_str());
                dps.append(this.dart_raw(q.ty).as_str());
                match (this.shape_of(q.ty) ?? shape::VOID) {
                    .CLOSURE(i) => {
                        nps.append(", Pointer<Void>");
                        dps.append(", Pointer<Void>");
                    },
                    default => {},
                }
            }
        }
        out.append(fmt4("  static final {} = _lib.lookupFunction<{} Function({}), {} Function(", copy e.name, move nret, move nps, move dret).as_str());
        out.append(fmt2("{})>('{}');\n", move dps, copy e.name).as_str());
    }
    out.append("}\n");
    // a class per export struct, freed by close() or, when it's collected, by a NativeFinalizer
    for (s&) in this.handles.items() {
        val cls = this.local(this.c.si(*s).name);
        val fr = this.free_name(*s);
        out.append(fmt4("\nfinal _{}_finalizer = NativeFinalizer(_lib.lookup<NativeFunction<Void Function(Pointer<Void>)>>('{}'));\n\n/// export struct {}; close() frees it (or the finalizer, once it's collected)\nclass {} implements Finalizable {{\n", copy cls, copy fr, S(this.c.si(*s).name), copy cls).as_str());
        out.append(fmt3("  Pointer<Void> _h;\n\n  {}._(this._h) {{\n    _{}_finalizer.attach(this, _h, detach: this);\n  }}\n\n", copy cls, copy cls, S("")).as_str());
        out.append(fmt2("  Pointer<Void> _handle() {{\n    if (_h == nullptr) {{\n      throw StateError('this {} is closed');\n    }}\n    return _h;\n  }}\n\n  void close() {{\n    if (_h != nullptr) {{\n      _{}_finalizer.detach(this);\n", copy cls, copy cls).as_str());
        out.append(fmt("      Native.{}(_h);\n      _h = nullptr;\n    }\n  }\n", copy fr).as_str());
        for (e&) in ents.items() {
            if (e.free_of != null) {
                continue;
            }
            val m = this.member_of(e.f, *s) ?? continue;
            val info = this.c.fi(e.f);
            out.append("\n");
            if (this.node_is_method(e.f, *s)) {
                val head = fmt2("{} {}", this.dart_ty(info.ret), dart_ident(m));
                out.append((try this.dart_fn(e.f, 1, head.as_str(), "  ")).as_str());
            } else if (m == "new" && this.made_by(e.f, *s)) {
                out.append((try this.dart_fn(e.f, 0, fmt("factory {}", copy cls).as_str(), "  ")).as_str());
            } else {
                val head = fmt2("static {} {}", this.dart_ty(info.ret), dart_ident(m));
                out.append((try this.dart_fn(e.f, 0, head.as_str(), "  ")).as_str());
            }
        }
        out.append("}\n");
    }
    // the functions
    for (e&) in ents.items() {
        if (e.free_of != null || this.class_of(e.f) != null) {
            continue;
        }
        val info = this.c.fi(e.f);
        out.append("\n");
        val head = fmt2("{} {}", this.dart_ty(info.ret), dart_ident(info.c_name));
        out.append((try this.dart_fn(e.f, 0, head.as_str(), "")).as_str());
    }
    return out;
}

// ---------- Swift (over the C header, imported as Clang module C<pkg>) ----------

fn swift_keyword(s: str) -> bool {
    val words: str[] = { "associatedtype", "class", "deinit", "enum", "extension", "fileprivate", "func", "import", "init", "inout", "internal", "let", "open", "operator", "private", "protocol", "public", "rethrows", "static", "struct", "subscript", "typealias", "var", "break", "case", "continue", "default", "defer", "do", "else", "fallthrough", "for", "guard", "if", "in", "repeat", "return", "switch", "where", "while", "as", "Any", "catch", "false", "is", "nil", "super", "self", "Self", "throw", "throws", "true", "try" };
    for (w) in words {
        if (w == s) {
            return true;
        }
    }
    return false;
}

fn swift_ident(s: str) -> std::string {
    if (swift_keyword(s)) {
        return fmt("`{}`", S(s));
    }
    return S(s);
}

fn swift_int(k: int_ty) -> str {
    match (k) {
        .I8 => { return "Int8"; },
        .I16 => { return "Int16"; },
        .I32 => { return "Int32"; },
        .I64 => { return "Int64"; },
        .U8 => { return "UInt8"; },
        .U16 => { return "UInt16"; },
        .U32 => { return "UInt32"; },
        .U64 => { return "UInt64"; },
        default => { return "Int"; },
    }
}

// the module the C header is imported as
attach fn swift_cmod(this: bind&) -> std::string {
    return fmt("C{}", S(this.pkg));
}

// a type as Swift imports its C form (named C types keep their C names)
attach fn swift_c(this: bind&, t: u32) -> std::string {
    match (this.shape_of(t) ?? shape::VOID) {
        .VOID => { return S("Void"); },
        .BOOL => { return S("Bool"); },
        .INT(k) => { return S(swift_int(k)); },
        .FLOAT(b) => {
            if (b == 32) {
                return S("Float");
            }
            return S("Double");
        },
        .CSTR => { return S("UnsafePointer<CChar>?"); },
        .PTR(x) => {
            if (x == VOID) {
                return S("UnsafeMutableRawPointer?");
            }
            match (this.shape_of(x) ?? shape::VOID) {
                .HANDLE(s) => { return S("OpaquePointer?"); },
                default => {},
            }
            return fmt("UnsafeMutablePointer<{}>?", this.swift_c(x));
        },
        .HANDLE(s) => { return S("OpaquePointer?"); },
        .CODE => { return S("UInt32"); },
        default => { return this.c_prim(t, false); },
    }
}

// a type as the Swift API shows it
attach fn swift_ty(this: bind&, t: u32) -> std::string {
    val h = this.lent_handle(t);
    if (h) {
        return this.local(this.c.si(h).name);
    }
    match (this.shape_of(t) ?? shape::VOID) {
        .CSTR => { return S("String?"); },
        .STR => { return S("String"); },
        .TEXT(x) => { return S("String"); },
        .STRUCT(s) => { return this.local(this.c.si(s).name); },
        .ENUM(e) => { return this.local(this.c.ei(e).name); },
        .PTR(x) => {
            if (x != VOID && !this.nullable_ptr(t)) {
                match (this.shape_of(x) ?? shape::VOID) {
                    .STRUCT(s) => { return fmt("inout {}", this.local(this.c.si(s).name)); },
                    default => {},
                }
            }
            return this.swift_c(t);
        },
        .HANDLE(s) => { return this.local(this.c.si(s).name); },
        .SLICE(x) => { return fmt("inout [{}]", this.swift_elem(x)); },
        .OPT(x) => { return fmt("{}?", this.swift_ty(x)); },
        .RESULT(e, x) => { return this.swift_ty(x); },
        .CLOSURE(i) => {
            match (*this.c.t.get(t)) {
                .FN_VAL(ps&, r) => {
                    var args: std::string = {};
                    for (p&) in ps.items() {
                        if (args.len() > 0) {
                            args.append(", ");
                        }
                        args.append(this.swift_ty(*p).as_str());
                    }
                    return fmt2("({}) -> {}", move args, this.swift_ty(r));
                },
                default => { return S("() -> Void"); },
            }
        },
        default => { return this.swift_c(t); },
    }
}

// a slice's element type: the C one (an enum's tag type), or the struct's name
attach fn swift_elem(this: bind&, t: u32) -> std::string {
    match (this.shape_of(t) ?? shape::VOID) {
        .STRUCT(s) => { return this.local(this.c.si(s).name); },
        default => { return this.swift_c(t); },
    }
}

// an expression turning API value v (of type t) into its C form, for numbers, bool, enums, structs
attach fn swift_in(this: bind&, t: u32, v: str) -> std::string {
    match (this.shape_of(t) ?? shape::VOID) {
        .ENUM(e) => { return fmt("{}.rawValue", S(v)); },
        default => { return S(v); },
    }
}

// an expression turning C value r (of type t) into the API's, for the plain types and str
attach fn swift_out(this: bind&, t: u32, r: str) -> std::string {
    match (this.shape_of(t) ?? shape::VOID) {
        .ENUM(e) => { return fmt2("{}(rawValue: {})!", this.local(this.c.ei(e).name), S(r)); },
        .STR => { return fmt("voltString({})", S(r)); },
        default => { return S(r); },
    }
}

// one parameter of a wrapper: its declaration, what the call passes, statements at the top (pre),
// and the scopes the call runs in (each `X { p in`, closed by `}`), with what starts each scope
struct swift_arg {
    decl: std::string = {};
    pass: std::string = {};
    pre: std::string = {};
    scopes: std::vec<std::string> = {};
    inside: std::vec<std::string> = {}; // statements at the start of each scope
}

attach fn swift_arg_of(this: bind&, t: u32, name0: str, a: swift_arg&) -> compile_error!void {
    val nm = swift_ident(name0);
    val n = nm.as_str();
    a.decl = fmt3("_ {}: {}", S(n), this.swift_ty(t), S(""));
    val h = this.lent_handle(t);
    if (h) {
        a.pass = fmt("{}.voltHandle()", S(n));
        return;
    }
    match (this.shape_of(t) ?? shape::VOID) {
        .STR => {
            a.pre = fmt2("var {}_s = {}\n", S(name0), S(n));
            put(&a.scopes, fmt2("{}_s.withUTF8 {{ {}_p in", S(name0), S(name0)));
            put(&a.inside, {});
            a.pass = fmt2("volt_str(ptr: {}_p.baseAddress, len: {}_p.count)", S(name0), S(name0));
        },
        .CSTR => {
            put(&a.scopes, fmt2("voltWithCString({}) {{ {}_p in", S(n), S(name0)));
            put(&a.inside, {});
            a.pass = fmt("{}_p", S(name0));
        },
        .PTR(x) => {
            if (x != VOID && !this.nullable_ptr(t)) {
                match (this.shape_of(x) ?? shape::VOID) {
                    .STRUCT(s) => {
                        a.pass = fmt("&{}", S(n));
                        return;
                    },
                    default => {},
                }
            }
            a.pass = S(n);
        },
        .SLICE(x) => {
            put(&a.scopes, fmt2("{}.withUnsafeMutableBufferPointer {{ {}_p in", S(n), S(name0)));
            put(&a.inside, {});
            a.pass = fmt3("{}(ptr: {}_p.baseAddress, len: {}_p.count)", this.c_prim(t, false), S(name0), S(name0));
        },
        .OPT(x) => {
            if (!this.simple_value(x)) {
                return fail(NO_SPAN, fmt("an optional {} can't come from Swift", this.c.ty_name(x)));
            }
            a.pre = fmt2("var {}_o = {}()\n", S(name0), this.c_prim(t, false));
            a.pre.append(fmt3("if let v = {} {{\n    {}_o.value = {}\n", S(n), S(name0), this.swift_in(x, "v")).as_str());
            a.pre.append(fmt("    {}_o.has = true\n}\n", S(name0)).as_str());
            a.pass = fmt("{}_o", S(name0));
        },
        .CLOSURE(i) => {
            match (*this.c.t.get(t)) {
                .FN_VAL(ps&, r) => {
                    // the closure, in a box the C function finds through its user pointer
                    put(&a.scopes, fmt2("withoutActuallyEscaping({}) {{ {}_f in", S(n), S(name0)));
                    put(&a.inside, fmt2("let {}_box = VoltBox({}_f)\n", S(name0), S(name0)));
                    put(&a.scopes, fmt("withExtendedLifetime({}_box) {", S(name0)));
                    put(&a.inside, {});
                    var params = S("u");
                    var args: std::string = {};
                    for (k) in 0..ps.len {
                        val ak = fmt("a{}", unum(@cast<u64>(k)));
                        params.append(fmt(", {}", copy ak).as_str());
                        if (k > 0) {
                            args.append(", ");
                        }
                        match (this.shape_of(*ps.at(k)) ?? shape::VOID) {
                            .STR => {},
                            default => {
                                if (!this.simple_value(*ps.at(k))) {
                                    return fail(NO_SPAN, fmt("a callback taking {} can't call Swift", this.c.ty_name(*ps.at(k))));
                                }
                            },
                        }
                        args.append(this.swift_out(*ps.at(k), ak.as_str()).as_str());
                    }
                    if (r != VOID && !this.simple_value(r)) {
                        return fail(NO_SPAN, fmt("a callback returning {} can't call Swift", this.c.ty_name(r)));
                    }
                    val call = fmt4("Unmanaged<VoltBox<{}>>.fromOpaque(u!).takeUnretainedValue().f({}){}", this.swift_ty(t), move args, S(""), S(""));
                    a.pass = fmt3("{{ {} in {} }}, Unmanaged.passUnretained({}_box).toOpaque()", move params, this.swift_in(r, call.as_str()), S(name0));
                },
                default => {},
            }
        },
        default => { a.pass = this.swift_in(t, n); },
    }
    return;
}

// does a call to f throw (it returns an error union)?
attach fn swift_throws(this: bind&, t: u32) -> bool {
    match (this.shape_of(t) ?? shape::VOID) {
        .RESULT(e, x) => { return true; },
        default => { return false; },
    }
}

// statements turning C result r (of type t) into what the wrapper returns (raw: a handle stays a
// pointer, for an init)
attach fn swift_result(this: bind&, t: u32, r: str, raw: bool) -> compile_error!std::string {
    match (this.shape_of(t) ?? shape::VOID) {
        .VOID => { return {}; },
        .CSTR => { return fmt("return {}.map {{ String(cString: $0) }}\n", S(r)); },
        .TEXT(x) => { return fmt("return voltTake({})\n", S(r)); },
        .HANDLE(s) => {
            if (raw) {
                return fmt("return {}!\n", S(r));
            }
            return fmt2("return {}(handle: {})\n", this.local(this.c.si(s).name), S(r));
        },
        .OPT(x) => {
            if (!this.simple_value(x)) {
                return fail(NO_SPAN, fmt("an optional {} can't go to Swift", this.c.ty_name(x)));
            }
            return fmt2("return {}.has ? {} : nil\n", S(r), this.swift_out(x, fmt("{}.value", S(r)).as_str()));
        },
        .SLICE(x) => {
            if (!this.simple_value(x)) {
                return fail(NO_SPAN, fmt("a slice of {} can't go to Swift", this.c.ty_name(x)));
            }
            return fmt2("return Array(UnsafeBufferPointer(start: {}.ptr, count: {}.len))\n", S(r), S(r));
        },
        .RESULT(e, x) => {
            var out = fmt("if {}.error != 0 {{\n", S(r));
            match (*this.c.t.get(e)) {
                .ENUM(id) => { out.append(fmt3("    throw voltError({}.error, {}.self)\n}}\n", S(r), this.local(this.c.ei(id).name), S("")).as_str()); },
                default => { out.append(fmt("    throw voltAnyError({}.error)\n}\n", S(r)).as_str()); },
            }
            out.append((try this.swift_result(x, fmt("{}.value", S(r)).as_str(), raw)).as_str());
            return out;
        },
        default => { return fmt("return {}\n", this.swift_out(t, r)); },
    }
}

attach fn swift_doc(this: bind&, f: u32, ind: str) -> std::string {
    val sp = this.c.dl(this.c.fi(f).decl).item.span;
    val d = doc_above(this.c.files.at(sp.file).text, @cast<usize>(sp.lo));
    if (d.len() == 0) {
        return {};
    }
    return fmt2("{}/// {}\n", S(ind), move d);
}

// a wrapper: its head (with the parameters from first on spliced in at {}), and its body, which
// calls the C function inside its parameters' scopes; first == 1: a method (self's handle first)
attach fn swift_fn(this: bind&, f: u32, first: usize, head: str, raw: bool, ind: str) -> compile_error!std::string {
    val info = this.c.fi(f);
    var decls: std::string = {};
    var passes: std::string = {};
    var pre: std::string = {};
    var scopes: std::vec<std::string> = {};
    var inside: std::vec<std::string> = {};
    if (first == 1) {
        passes = S("voltHandle()");
    }
    for (k) in first..info.params.len {
        val p = info.params.at(k);
        var a: swift_arg = {};
        try this.swift_arg_of(p.ty, p.name, &a);
        if (decls.len() > 0) {
            decls.append(", ");
        }
        decls.append(a.decl.as_str());
        if (passes.len() > 0) {
            passes.append(", ");
        }
        passes.append(a.pass.as_str());
        pre.append(a.pre.as_str());
        for (i) in 0..a.scopes.len {
            put(&scopes, copy *a.scopes.at(i));
            put(&inside, copy *a.inside.at(i));
        }
    }
    val throws = this.swift_throws(info.ret);
    var rt = S("return ");
    if (throws) {
        rt = S("return try ");
    }
    // the innermost body: the call, the error check, the result
    var inner: std::string = {};
    if (info.ret == VOID) {
        inner = fmt2("{}.{}(", this.swift_cmod(), S(info.c_name));
        inner.append(fmt("{})\n", move passes).as_str());
    } else {
        inner = fmt3("let r = {}.{}({})\n", this.swift_cmod(), S(info.c_name), move passes);
        inner.append((try this.swift_result(info.ret, "r", raw)).as_str());
    }
    var k = scopes.len;
    while (k > 0) {
        k -= 1;
        var level = fmt2("{}{}\n", copy rt, copy *scopes.at(k));
        var body = copy *inside.at(k);
        body.append(inner.as_str());
        level.append(indent_n(body.as_str(), 4).as_str());
        level.append("}\n");
        inner = move level;
    }
    var body = move pre;
    body.append(inner.as_str());
    var spec = S("");
    if (throws) {
        spec = S(" throws");
    }
    var out = this.swift_doc(f, ind);
    out.append(fmt2("{}{}\n", S(ind), replace_all(replace_all(head, "{}", decls.as_str()).as_str(), " THROWS", spec.as_str())).as_str());
    out.append(indent_n(body.as_str(), ind.len + 4).as_str());
    out.append(fmt("{}}\n", S(ind)).as_str());
    return out;
}

// " -> T" for a wrapper's result (nothing for void)
attach fn swift_ret(this: bind&, t: u32) -> std::string {
    match (this.shape_of(t) ?? shape::VOID) {
        .VOID => { return {}; },
        .RESULT(e, x) => { return this.swift_ret(x); },
        .SLICE(x) => { return fmt(" -> [{}]", this.swift_elem(x)); },
        .PTR(x) => { return fmt(" -> {}", this.swift_c(t)); },
        default => { return fmt(" -> {}", this.swift_ty(t)); },
    }
}

attach fn swift_text(this: bind&) -> compile_error!std::string {
    val ents = this.entries();
    val p = this.pkg;
    val cm = this.swift_cmod();
    var out = fmt("// {}: generated by voltc bindings; the Volt package for Swift. It calls the C functions\n", S(p));
    out.append(fmt3("// of --lang c's header, imported as module {}: put {}.h in a directory with a module.modulemap\n", copy cm, S(p), S("")).as_str());
    out.append(fmt3("//   module {} {{ header \"{}.h\" export * }}\n// and build with -I <that directory> -L <the library's> -l", copy cm, S(p), S("")).as_str());
    out.append(fmt("{}. Errors are thrown as their error set's\n// enum; an export struct is a class (close(), or deinit, frees it).\n", S(p)).as_str());
    out.append(fmt("import {}\n", copy cm).as_str());
    out.append("\n/// an error code no error set here names\npublic struct VoltError: Error, CustomStringConvertible {\n    public let code: UInt32\n    public var description: String { \"error \\(code)\" }\n}\n");
    out.append("\nfunc voltError<E: RawRepresentable & Error>(_ code: UInt32, _ set: E.Type) -> Error where E.RawValue == UInt32 {\n    return E(rawValue: code) ?? VoltError(code: code)\n}\n");
    out.append("\nfunc voltAnyError(_ code: UInt32) -> Error {\n    switch code {\n");
    for (c&) in this.all_codes().items() {
        out.append(fmt3("    case {}: return {}.{}\n", num(c.code), copy c.set, S(c.name)).as_str());
    }
    out.append("    default: return VoltError(code: code)\n    }\n}\n");
    out.append("\nfunc voltString(_ s: volt_str) -> String {\n    return String(decoding: UnsafeBufferPointer(start: s.ptr, count: s.len), as: UTF8.self)\n}\n");
    out.append("\nfunc voltWithCString<R>(_ s: String?, _ body: (UnsafePointer<CChar>?) throws -> R) rethrows -> R {\n    guard let s else {\n        return try body(nil)\n    }\n    return try s.withCString(body)\n}\n");
    if (this.texts.len > 0) {
        out.append("\n// owned text: copied into a String, then freed\nfunc voltTake(_ t: volt_text) -> String {\n    let s = String(decoding: UnsafeBufferPointer(start: t.ptr, count: t.len), as: UTF8.self)\n    volt_text_free(t)\n    return s\n}\n");
    }
    if (this.closures.len > 0) {
        out.append("\n// a closure passed for a callback, which the C function finds through its user pointer\nfinal class VoltBox<F> {\n    let f: F\n\n    init(_ f: F) {\n        self.f = f\n    }\n}\n");
    }
    for (et&) in this.codes.items() {
        match (*this.c.t.get(*et)) {
            .ENUM(e) => {
                val info = this.c.ei(e);
                out.append(fmt2("\n/// error set {}\npublic enum {}: UInt32, Error {{\n", S(info.name), this.local(info.name)).as_str());
                for (i) in 0..info.names.len {
                    out.append(fmt2("    case {} = {}\n", swift_ident(*info.names.at(i)), num(*info.values.at(i))).as_str());
                }
                out.append("}\n");
            },
            default => {},
        }
    }
    for (e&) in this.enums.items() {
        val info = this.c.ei(*e);
        out.append(fmt2("\npublic enum {}: {} {{\n", this.local(info.name), S(swift_int(info.tag))).as_str());
        for (i) in 0..info.names.len {
            out.append(fmt2("    case {} = {}\n", swift_ident(*info.names.at(i)), num(*info.values.at(i))).as_str());
        }
        out.append("}\n");
    }
    for (s&) in this.structs.items() {
        val info = this.c.si(*s);
        out.append(fmt2("\npublic typealias {} = {}\n", this.local(info.name), this.c_named(info.name, false)).as_str());
    }
    // a class per export struct
    for (s&) in this.handles.items() {
        val cls = this.local(this.c.si(*s).name);
        out.append(fmt2("\n/// export struct {}; close() (or deinit) frees it\npublic final class {} {{\n    private var voltRaw: OpaquePointer?\n\n", S(this.c.si(*s).name), copy cls).as_str());
        out.append("    init(handle: OpaquePointer?) {\n        voltRaw = handle\n    }\n\n    deinit {\n        close()\n    }\n\n");
        out.append(fmt3("    public func close() {{\n        if let h = voltRaw {{\n            {}.{}(h)\n            voltRaw = nil\n        }}\n    }}\n\n", copy cm, this.free_name(*s), S("")).as_str());
        out.append(fmt("    func voltHandle() -> OpaquePointer {\n        guard let h = voltRaw else {\n            preconditionFailure(\"this {} is closed\")\n        }\n        return h\n    }\n", copy cls).as_str());
        for (e&) in ents.items() {
            if (e.free_of != null) {
                continue;
            }
            val m = this.member_of(e.f, *s) ?? continue;
            val info = this.c.fi(e.f);
            out.append("\n");
            if (this.node_is_method(e.f, *s)) {
                val head = fmt2("public func {}({{}}) THROWS{} {{", swift_ident(m), this.swift_ret(info.ret));
                out.append((try this.swift_fn(e.f, 1, head.as_str(), false, "    ")).as_str());
            } else if (m == "new" && this.made_by(e.f, *s)) {
                // an init: make the handle, then the instance holding it
                var names: std::string = {};
                var tr = S("");
                if (this.swift_throws(info.ret)) {
                    tr = S("try ");
                }
                for (k) in 0..info.params.len {
                    if (k > 0) {
                        names.append(", ");
                    }
                    names.append(swift_ident(info.params.at(k).name).as_str());
                }
                out.append(this.swift_doc(e.f, "    ").as_str());
                var args: std::string = {};
                for (k) in 0..info.params.len {
                    if (k > 0) {
                        args.append(", ");
                    }
                    args.append(fmt2("_ {}: {}", swift_ident(info.params.at(k).name), this.swift_ty(info.params.at(k).ty)).as_str());
                }
                var spec = S("");
                if (this.swift_throws(info.ret)) {
                    spec = S(" throws");
                }
                out.append(fmt3("    public convenience init({}){} {{\n        self.init(handle: ", move args, move spec, S("")).as_str());
                out.append(fmt3("{}{}.voltMake({}))\n    }}\n\n", move tr, copy cls, move names).as_str());
                out.append((try this.swift_fn(e.f, 0, "private static func voltMake({}) THROWS -> OpaquePointer {", true, "    ")).as_str());
            } else {
                val head = fmt2("public static func {}({{}}) THROWS{} {{", swift_ident(m), this.swift_ret(info.ret));
                out.append((try this.swift_fn(e.f, 0, head.as_str(), false, "    ")).as_str());
            }
        }
        out.append("}\n");
    }
    // the functions
    for (e&) in ents.items() {
        if (e.free_of != null || this.class_of(e.f) != null) {
            continue;
        }
        val info = this.c.fi(e.f);
        out.append("\n");
        val head = fmt2("public func {}({{}}) THROWS{} {{", swift_ident(info.c_name), this.swift_ret(info.ret));
        out.append((try this.swift_fn(e.f, 0, head.as_str(), false, "")).as_str());
    }
    return out;
}

// ---------- Kotlin/Native (over the C header, through cinterop as package c<pkg>) ----------

fn kt_keyword(s: str) -> bool {
    val words: str[] = { "as", "break", "class", "continue", "do", "else", "false", "for", "fun", "if", "in", "interface", "is", "null", "object", "package", "return", "super", "this", "throw", "true", "try", "typealias", "typeof", "val", "var", "when", "while" };
    for (w) in words {
        if (w == s) {
            return true;
        }
    }
    return false;
}

fn kt_ident(s: str) -> std::string {
    if (kt_keyword(s)) {
        return fmt("`{}`", S(s));
    }
    return S(s);
}

fn kt_int(k: int_ty) -> str {
    match (k) {
        .I8 => { return "Byte"; },
        .I16 => { return "Short"; },
        .I32 => { return "Int"; },
        .I64 => { return "Long"; },
        .ISIZE => { return "Long"; },
        .U8 => { return "UByte"; },
        .U16 => { return "UShort"; },
        .U32 => { return "UInt"; },
        default => { return "ULong"; },
    }
}

// the package cinterop puts the C declarations in
attach fn kt_cpkg(this: bind&) -> std::string {
    return fmt("c{}", S(this.pkg));
}

// a type as cinterop gives its C form
attach fn kt_c(this: bind&, t: u32) -> std::string {
    match (this.shape_of(t) ?? shape::VOID) {
        .VOID => { return S("Unit"); },
        .BOOL => { return S("Boolean"); },
        .INT(k) => { return S(kt_int(k)); },
        .FLOAT(b) => {
            if (b == 32) {
                return S("Float");
            }
            return S("Double");
        },
        .ENUM(e) => { return S(kt_int(this.c.ei(e).tag)); },
        .CODE => { return S("UInt"); },
        .CSTR => { return S("CPointer<ByteVar>?"); },
        .PTR(x) => {
            if (x == VOID) {
                return S("COpaquePointer?");
            }
            match (this.shape_of(x) ?? shape::VOID) {
                .HANDLE(s) => { return fmt("CPointer<cnames.structs.{}>?", this.c_named(this.c.si(s).name, false)); },
                default => {},
            }
            return fmt("CPointer<{}>?", this.kt_var(x));
        },
        .HANDLE(s) => { return fmt("CPointer<cnames.structs.{}>?", this.c_named(this.c.si(s).name, false)); },
        default => { return fmt("CValue<{}>", this.c_prim(t, false)); },
    }
}

// the C variable type cinterop has for a type (IntVar, a struct's class, CPointerVar<...>)
attach fn kt_var(this: bind&, t: u32) -> std::string {
    match (this.shape_of(t) ?? shape::VOID) {
        .BOOL => { return S("BooleanVar"); },
        .INT(k) => { return fmt("{}Var", S(kt_int(k))); },
        .FLOAT(b) => {
            if (b == 32) {
                return S("FloatVar");
            }
            return S("DoubleVar");
        },
        .ENUM(e) => { return fmt("{}Var", S(kt_int(this.c.ei(e).tag))); },
        .CODE => { return S("UIntVar"); },
        .PTR(x) => { return fmt("CPointerVar<{}>", this.kt_var(x)); },
        .CSTR => { return S("CPointerVar<ByteVar>"); },
        .HANDLE(s) => { return fmt("CPointerVar<cnames.structs.{}>", this.c_named(this.c.si(s).name, false)); },
        default => { return this.c_prim(t, false); },
    }
}

// the primitive array a slice of t is in Kotlin (none: a List of structs)
fn kt_array(k: str) -> std::string {
    return fmt("{}Array", S(k));
}

// a type as the Kotlin API shows it
attach fn kt_ty(this: bind&, t: u32) -> std::string {
    val h = this.lent_handle(t);
    if (h) {
        return this.local(this.c.si(h).name);
    }
    match (this.shape_of(t) ?? shape::VOID) {
        .CSTR => { return S("String?"); },
        .STR => { return S("String"); },
        .TEXT(x) => { return S("String"); },
        .STRUCT(s) => { return this.local(this.c.si(s).name); },
        .ENUM(e) => { return this.local(this.c.ei(e).name); },
        .PTR(x) => {
            val s = this.ref_struct(t);
            if (s) {
                var n = this.local(this.c.si(s).name);
                if (this.nullable_ptr(t)) {
                    n.push('?');
                }
                return n;
            }
            return this.kt_c(t);
        },
        .HANDLE(s) => { return this.local(this.c.si(s).name); },
        .SLICE(x) => {
            match (this.shape_of(x) ?? shape::VOID) {
                .STRUCT(s) => { return fmt("List<{}>", this.local(this.c.si(s).name)); },
                default => { return kt_array(this.kt_c(x).as_str()); },
            }
        },
        .OPT(x) => { return fmt("{}?", this.kt_ty(x)); },
        .RESULT(e, x) => { return this.kt_ty(x); },
        .CLOSURE(i) => {
            match (*this.c.t.get(t)) {
                .FN_VAL(ps&, r) => {
                    var args: std::string = {};
                    for (p&) in ps.items() {
                        if (args.len() > 0) {
                            args.append(", ");
                        }
                        args.append(this.kt_ty(*p).as_str());
                    }
                    return fmt2("({}) -> {}", move args, this.kt_ty(r));
                },
                default => { return S("() -> Unit"); },
            }
        },
        default => { return this.kt_c(t); },
    }
}

// an expression turning API value v (of type t) into its C form, for numbers, bool, enums, structs
attach fn kt_in(this: bind&, t: u32, v: str) -> std::string {
    match (this.shape_of(t) ?? shape::VOID) {
        .ENUM(e) => { return fmt("{}.value", S(v)); },
        .STRUCT(s) => { return fmt("{}.toC()", S(v)); },
        default => { return S(v); },
    }
}

// an expression turning C value r (of type t) into the API's, for the plain types and str (r is a
// CValue for a struct or str, or the struct's variable when var_ is true)
attach fn kt_out(this: bind&, t: u32, r: str, var_: bool) -> std::string {
    match (this.shape_of(t) ?? shape::VOID) {
        .ENUM(e) => { return fmt2("{}.of({})", this.local(this.c.ei(e).name), S(r)); },
        .STRUCT(s) => {
            if (var_) {
                return fmt("{}.toKotlin()", S(r));
            }
            return fmt("{}.useContents {{ toKotlin() }}", S(r));
        },
        .STR => {
            if (var_) {
                return fmt("voltString({}.readValue())", S(r));
            }
            return fmt("voltString({})", S(r));
        },
        default => { return S(r); },
    }
}

// one parameter of a wrapper: its declaration, what the call passes, the statements before the call
// (inside memScoped), what copies changes back, and the callbacks' boxes (rethrown after the call)
struct kt_arg {
    decl: std::string = {};
    pass: std::string = {};
    pre: std::string = {};
    after: std::string = {};
    scope: std::string = {}; // a usePinned block the call runs in
    box: std::string = {}; // a callback: the name its box and StableRef are named after
    box_ty: std::string = {};
    scoped: bool = false; // it needs memScoped
}

attach fn kt_arg_of(this: bind&, t: u32, name0: str, a: kt_arg&) -> compile_error!void {
    val nm = kt_ident(name0);
    val n = nm.as_str();
    a.decl = fmt2("{}: {}", S(n), this.kt_ty(t));
    val h = this.lent_handle(t);
    if (h) {
        a.pass = fmt("{}.voltHandle()", S(n));
        return;
    }
    match (this.shape_of(t) ?? shape::VOID) {
        .STR => {
            a.pass = fmt("voltStr({})", S(n));
            a.scoped = true;
        },
        .CSTR => { a.pass = S(n); },
        .PTR(x) => {
            val s = this.ref_struct(t);
            if (s) {
                // a copy goes in, and what Volt changed comes back
                val cn = this.c_named(this.c.si(s).name, false);
                a.scoped = true;
                if (this.nullable_ptr(t)) {
                    a.pre = fmt4("val {}_p = if ({} == null) null else alloc<{}>().also {{ {}.write(it) }}\n", S(name0), S(n), copy cn, S(n));
                    a.pass = fmt("{}_p?.ptr", S(name0));
                    a.after = fmt3("if ({} != null) {{\n    {}.readFrom({}_p!!)\n}}\n", S(n), S(n), S(name0));
                } else {
                    a.pre = fmt3("val {}_p = alloc<{}>().also {{ {}.write(it) }}\n", S(name0), copy cn, S(n));
                    a.pass = fmt("{}_p.ptr", S(name0));
                    a.after = fmt2("{}.readFrom({}_p)\n", S(n), S(name0));
                }
                return;
            }
            a.pass = S(n);
        },
        .SLICE(x) => {
            val sc = this.c_prim(t, false);
            match (this.shape_of(x) ?? shape::VOID) {
                .STRUCT(s) => {
                    // the elements copied into C memory, and back
                    val cn = this.c_named(this.c.si(s).name, false);
                    a.scoped = true;
                    a.pre = fmt3("val {}_p = allocArray<{}>({}.size.coerceAtLeast(1))\n", S(name0), copy cn, S(n));
                    a.pre.append(fmt2("{}.forEachIndexed {{ i, e -> e.write({}_p[i]) }}\n", S(n), S(name0)).as_str());
                    a.pass = fmt4("cValue<{}> {{ ptr = {}_p; len = {}.size.convert() }}", copy sc, S(name0), S(n), S(""));
                    a.after = fmt2("{}.forEachIndexed {{ i, e -> e.readFrom({}_p[i]) }}\n", S(n), S(name0));
                },
                default => {
                    if (!this.simple_value(x)) {
                        return fail(NO_SPAN, fmt("a slice of {} can't come from Kotlin", this.c.ty_name(x)));
                    }
                    // the array itself, pinned: what Volt writes is in it
                    a.scope = fmt2("{}.usePinned {{ {}_pin ->", S(n), S(name0));
                    a.pass = fmt4("cValue<{}> {{ ptr = if ({}.isEmpty()) null else {}_pin.addressOf(0); len = ", copy sc, S(n), S(name0), S(""));
                    a.pass.append(fmt("{}.size.convert() }", S(n)).as_str());
                },
            }
        },
        .OPT(x) => {
            if (!this.simple_value(x)) {
                return fail(NO_SPAN, fmt("an optional {} can't come from Kotlin", this.c.ty_name(x)));
            }
            var set = fmt2("value = {}", this.kt_in(x, n), S(""));
            match (this.shape_of(x) ?? shape::VOID) {
                .STRUCT(s) => { set = fmt("{}.write(value)", S(n)); },
                default => {},
            }
            a.pass = fmt4("cValue<{}> {{ if ({} != null) {{ {}; has = true }} }}", this.c_prim(t, false), S(n), move set, S(""));
        },
        .CLOSURE(i) => {
            match (*this.c.t.get(t)) {
                .FN_VAL(ps&, r) => {
                    // the function, in a box the C function finds through a StableRef; what it
                    // throws is kept (the later calls are skipped) and thrown once the call is back
                    var params = S("u: COpaquePointer?");
                    var args: std::string = {};
                    for (k) in 0..ps.len {
                        val ak = fmt("a{}", unum(@cast<u64>(k)));
                        match (this.shape_of(*ps.at(k)) ?? shape::VOID) {
                            .STR => {},
                            default => {
                                if (!this.simple_value(*ps.at(k))) {
                                    return fail(NO_SPAN, fmt("a callback taking {} can't call Kotlin", this.c.ty_name(*ps.at(k))));
                                }
                            },
                        }
                        params.append(fmt2(", {}: {}", copy ak, this.kt_c(*ps.at(k))).as_str());
                        if (k > 0) {
                            args.append(", ");
                        }
                        args.append(this.kt_out(*ps.at(k), ak.as_str(), false).as_str());
                    }
                    var dflt: std::string = {};
                    match (this.shape_of(r) ?? shape::VOID) {
                        .VOID => {},
                        .BOOL => { dflt = S("false"); },
                        .FLOAT(b) => {
                            dflt = S("0.0");
                            if (b == 32) {
                                dflt = S("0.0f");
                            }
                        },
                        .INT(k) => { dflt = fmt("0.to{}()", S(kt_int(k))); },
                        .ENUM(e) => { dflt = fmt("0.to{}()", S(kt_int(this.c.ei(e).tag))); },
                        .CODE => { dflt = S("0u"); },
                        default => { return fail(NO_SPAN, fmt("a callback returning {} can't call Kotlin", this.c.ty_name(r))); },
                    }
                    var ret = S("Unit");
                    if (dflt.len() > 0) {
                        ret = copy dflt;
                    }
                    val call = fmt2("b.f({})", move args, S(""));
                    val ft = this.kt_ty(t);
                    a.box = S(name0);
                    a.box_ty = fmt2("VoltBox<{}>({})", copy ft, S(n));
                    a.pass = fmt4("staticCFunction {{ {} ->\n    val b = u!!.asStableRef<VoltBox<{}>>().get()\n    if (b.error != null) {}", move params, copy ft, copy ret, S(""));
                    a.pass.append(fmt3(" else try {{\n        {}\n    }} catch (e: Throwable) {{\n        b.error = e\n        {}\n    }}\n}}", this.kt_in(r, call.as_str()), copy ret, S("")).as_str());
                    a.pass.append(fmt(", {}_ref.asCPointer()", S(name0)).as_str());
                },
                default => {},
            }
        },
        default => { a.pass = this.kt_in(t, n); },
    }
    return;
}

// an expression turning C result r (of type t) into the API's value (raw: a handle stays a pointer)
attach fn kt_result(this: bind&, t: u32, r: str, raw: bool) -> compile_error!std::string {
    match (this.shape_of(t) ?? shape::VOID) {
        .VOID => { return S("Unit"); },
        .CSTR => { return fmt("{}?.toKString()", S(r)); },
        .TEXT(x) => { return fmt("voltTake({})", S(r)); },
        .HANDLE(s) => {
            if (raw) {
                return fmt("{}!!", S(r));
            }
            return fmt2("{}({}!!)", this.local(this.c.si(s).name), S(r));
        },
        .OPT(x) => {
            if (!this.simple_value(x)) {
                return fail(NO_SPAN, fmt("an optional {} can't go to Kotlin", this.c.ty_name(x)));
            }
            return fmt2("{}.useContents {{ if (has) {} else null }}", S(r), this.kt_out(x, "value", true));
        },
        .SLICE(x) => {
            match (this.shape_of(x) ?? shape::VOID) {
                .STRUCT(s) => { return fmt("{}.useContents {{ List(len.toInt()) {{ ptr!![it].toKotlin() }} }", S(r)); },
                default => {},
            }
            if (!this.simple_value(x)) {
                return fail(NO_SPAN, fmt("a slice of {} can't go to Kotlin", this.c.ty_name(x)));
            }
            return fmt2("{}.useContents {{ {}(len.toInt()) {{ ptr!![it] }} }", S(r), kt_array(this.kt_c(x).as_str()));
        },
        .RESULT(e, x) => {
            // the value is read inside useContents: a text or a handle by its fields
            var v: std::string = {};
            match (this.shape_of(x) ?? shape::VOID) {
                .VOID => { v = S("Unit"); },
                .TEXT(y) => { v = S("voltTakeVar(value)"); },
                .STRUCT(s) => { v = S("value.toKotlin()"); },
                .STR => { v = S("voltString(value.readValue())"); },
                .HANDLE(s) => {
                    if (raw) {
                        v = S("value!!");
                    } else {
                        v = fmt("{}(value!!)", this.local(this.c.si(s).name));
                    }
                },
                .OPT(y) => { v = fmt("if (value.has) {} else null", this.kt_out(y, "value.value", true)); },
                default => {
                    if (!this.simple_value(x)) {
                        return fail(NO_SPAN, fmt("{} can't go to Kotlin", this.c.ty_name(x)));
                    }
                    v = this.kt_out(x, "value", true);
                },
            }
            return fmt2("{}.useContents {{\n    if (error != 0u) throw voltError(error)\n    {}\n}}", S(r), move v);
        },
        default => { return this.kt_out(t, r, false); },
    }
}

// ": T" for a wrapper's result (nothing for Unit)
attach fn kt_ret(this: bind&, t: u32) -> std::string {
    match (this.shape_of(t) ?? shape::VOID) {
        .VOID => { return {}; },
        .RESULT(e, x) => { return this.kt_ret(x); },
        .SLICE(x) => { return fmt(": {}", this.kt_ty(t)); },
        .PTR(x) => { return fmt(": {}", this.kt_c(t)); },
        default => { return fmt(": {}", this.kt_ty(t)); },
    }
}

attach fn kt_doc(this: bind&, f: u32, ind: str) -> std::string {
    val sp = this.c.dl(this.c.fi(f).decl).item.span;
    val d = doc_above(this.c.files.at(sp.file).text, @cast<usize>(sp.lo));
    if (d.len() == 0) {
        return {};
    }
    return fmt2("{}/** {} */\n", S(ind), move d);
}

// a wrapper: its head (the parameters from first on spliced in at {}) and body; first == 1: a
// method (its own handle first)
attach fn kt_fn(this: bind&, f: u32, first: usize, head: str, raw: bool, ind: str) -> compile_error!std::string {
    val info = this.c.fi(f);
    var decls: std::string = {};
    var passes: std::string = {};
    var pre: std::string = {};
    var after: std::string = {};
    var scopes: std::vec<std::string> = {};
    var boxes: std::vec<std::string> = {};
    var box_tys: std::vec<std::string> = {};
    var scoped = false;
    if (first == 1) {
        passes = S("voltHandle()");
    }
    for (k) in first..info.params.len {
        val p = info.params.at(k);
        var a: kt_arg = {};
        try this.kt_arg_of(p.ty, p.name, &a);
        if (decls.len() > 0) {
            decls.append(", ");
        }
        decls.append(a.decl.as_str());
        if (passes.len() > 0) {
            passes.append(", ");
        }
        passes.append(a.pass.as_str());
        pre.append(a.pre.as_str());
        after.append(a.after.as_str());
        if (a.scope.len() > 0) {
            put(&scopes, copy a.scope);
        }
        if (a.box.len() > 0) {
            put(&boxes, copy a.box);
            put(&box_tys, copy a.box_ty);
        }
        scoped = scoped || a.scoped;
    }
    // the innermost body: the call, a callback's error, the result, what comes back
    var inner = copy pre;
    val call = fmt3("{}.{}({})", this.kt_cpkg(), S(info.c_name), move passes);
    if (info.ret == VOID) {
        inner.append(fmt("{}\n", copy call).as_str());
    } else {
        inner.append(fmt("val volt_r = {}\n", copy call).as_str());
    }
    for (b&) in boxes.items() {
        inner.append(fmt("{}_box.error?.let { throw it }\n", copy *b).as_str());
    }
    if (info.ret != VOID) {
        inner.append(fmt("val volt_v = {}\n", try this.kt_result(info.ret, "volt_r", raw)).as_str());
    }
    inner.append(after.as_str());
    if (info.ret != VOID) {
        inner.append("volt_v\n");
    }
    var k = scopes.len;
    while (k > 0) {
        k -= 1;
        var level = fmt("{}\n", copy *scopes.at(k));
        level.append(indent_n(inner.as_str(), 4).as_str());
        level.append("}\n");
        inner = move level;
    }
    if (scoped) {
        var level = S("memScoped {\n");
        level.append(indent_n(inner.as_str(), 4).as_str());
        level.append("}\n");
        inner = move level;
    }
    // callbacks: a StableRef to each box, disposed after the call
    k = boxes.len;
    while (k > 0) {
        k -= 1;
        val bn = boxes.at(k);
        var level = fmt2("val {}_box = {}\n", copy *bn, copy *box_tys.at(k));
        level.append(fmt2("val {}_ref = StableRef.create({}_box)\ntry {{\n", copy *bn, copy *bn).as_str());
        level.append(indent_n(inner.as_str(), 4).as_str());
        level.append(fmt("}} finally {{\n    {}_ref.dispose()\n}}\n", copy *bn).as_str());
        inner = move level;
    }
    var out = this.kt_doc(f, ind);
    out.append(fmt2("{}{}\n", S(ind), replace_all(head, "{}", decls.as_str())).as_str());
    out.append(indent_n(inner.as_str(), ind.len + 4).as_str());
    out.append(fmt("{}}\n", S(ind)).as_str());
    return out;
}

attach fn kt_text(this: bind&) -> compile_error!std::string {
    val ents = this.entries();
    val p = this.pkg;
    val cp = this.kt_cpkg();
    var out = fmt("// {}: generated by voltc bindings; the Volt package for Kotlin/Native. It calls the C\n", S(p));
    out.append(fmt3("// functions of --lang c's header through cinterop, in package {}: a {}.def of\n//   headers = {}.h\n", copy cp, S(p), S(p)).as_str());
    out.append(fmt3("//   package = {}\n// (cinterop -def {}.def -compiler-option -I<dir> -o {}.klib; then kotlinc-native -l ", copy cp, S(p), S(p)).as_str());
    out.append(fmt3("{}.klib\n// -linker-options \"-L<dir> -l{}\"). Errors are thrown as VoltException, one subclass per error set;\n// an export struct is an AutoCloseable class (a Cleaner frees it too, once it's collected).\n", S(p), S(p), S("")).as_str());
    out.append("@file:OptIn(kotlinx.cinterop.ExperimentalForeignApi::class, kotlin.experimental.ExperimentalNativeApi::class, ExperimentalUnsignedTypes::class)\n@file:Suppress(\"ClassName\", \"FunctionName\", \"EnumEntryName\", \"LocalVariableName\", \"PropertyName\")\n\n");
    out.append(fmt2("package {}\n\nimport {}.*\nimport kotlinx.cinterop.*\nimport kotlin.native.ref.createCleaner\n", S(p), copy cp).as_str());
    out.append("\n/** an error a Volt function returned: its code and name */\nopen class VoltException(val code: UInt, val name: String) : Exception(name)\n");
    out.append("\ninternal fun voltError(code: UInt): VoltException = when (code) {\n");
    for (c&) in this.all_codes().items() {
        out.append(fmt3("    {}u -> {}(code, \"{}\")\n", num(c.code), copy c.set, S(c.name)).as_str());
    }
    out.append("    else -> VoltException(code, \"error\")\n}\n");
    for (et&) in this.codes.items() {
        match (*this.c.t.get(*et)) {
            .ENUM(e) => {
                val info = this.c.ei(e);
                val n = this.local(info.name);
                out.append(fmt3("\n/** error set {}: thrown for its errors; its codes */\nclass {}(code: UInt, name: String) : VoltException(code, name) {{\n    companion object {{\n", S(info.name), copy n, S("")).as_str());
                for (i) in 0..info.names.len {
                    out.append(fmt2("        const val {}: UInt = {}u\n", S(*info.names.at(i)), num(*info.values.at(i))).as_str());
                }
                out.append("    }\n}\n");
            },
            default => {},
        }
    }
    out.append("\ninternal fun voltString(s: CValue<volt_str>): String = s.useContents { if (len == 0UL) \"\" else ptr!!.readBytes(len.toInt()).decodeToString() }\n");
    out.append("\n// a String's UTF-8 bytes, in the memScoped block's memory\ninternal fun MemScope.voltStr(s: String): CValue<volt_str> {\n    val b = s.encodeToByteArray()\n    val p = allocArray<UByteVar>(b.size.coerceAtLeast(1))\n    b.forEachIndexed { i, x -> p[i] = x.toUByte() }\n    return cValue<volt_str> {\n        ptr = p\n        len = b.size.convert()\n    }\n}\n");
    if (this.texts.len > 0) {
        out.append("\n// owned text: copied into a String, then freed\ninternal fun voltTakeVar(t: volt_text): String {\n    val s = if (t.len == 0UL) \"\" else t.ptr!!.readBytes(t.len.toInt()).decodeToString()\n    t.drop?.invoke(t.owner)\n    return s\n}\n\ninternal fun voltTake(t: CValue<volt_text>): String = t.useContents { voltTakeVar(this) }\n");
    }
    if (this.closures.len > 0) {
        out.append("\n// a function passed for a callback, and what it threw\ninternal class VoltBox<F>(val f: F) {\n    var error: Throwable? = null\n}\n");
    }
    for (e&) in this.enums.items() {
        val info = this.c.ei(*e);
        val n = this.local(info.name);
        val tag = S(kt_int(info.tag));
        out.append(fmt2("\nenum class {}(val value: {}) {{\n", copy n, copy tag).as_str());
        for (i) in 0..info.names.len {
            var sep = ",";
            if (i + 1 == info.names.len) {
                sep = ";";
            }
            out.append(fmt4("    {}({}.to{}()){}\n", kt_ident(*info.names.at(i)), num(*info.values.at(i)), copy tag, S(sep)).as_str());
        }
        out.append(fmt2("\n    companion object {{\n        fun of(v: {}): {} = entries.first {{ it.value == v }}\n    }}\n}}\n", copy tag, copy n).as_str());
    }
    // structs: data classes, copied to and from C
    for (s&) in this.structs.items() {
        val info = this.c.si(*s);
        val n = this.local(info.name);
        val cn = this.c_named(info.name, false);
        var fields: std::string = {};
        var writes: std::string = {};
        var reads: std::string = {};
        var news: std::string = {};
        for (f&) in info.fields.items() {
            val fname = kt_ident(f.name);
            match (*this.c.t.get(f.ty)) {
                .ARRAY(e, k) => { return fail(NO_SPAN, fmt2("struct {} has an array field ({}), which Kotlin bindings can't copy", S(info.name), S(f.name))); },
                default => {},
            }
            if (fields.len() > 0) {
                fields.append(", ");
                news.append(", ");
            }
            match (this.shape_of(f.ty) ?? shape::VOID) {
                .STRUCT(fs) => {
                    fields.append(fmt2("var {}: {}", copy fname, this.local(this.c.si(fs).name)).as_str());
                    writes.append(fmt2("    {}.write(c.{})\n", copy fname, copy fname).as_str());
                    reads.append(fmt2("    {}.readFrom(c.{})\n", copy fname, copy fname).as_str());
                    news.append(fmt("{}.toKotlin()", copy fname).as_str());
                },
                default => {
                    fields.append(fmt2("var {}: {}", copy fname, this.kt_c(f.ty)).as_str());
                    writes.append(fmt2("    c.{} = {}\n", copy fname, copy fname).as_str());
                    reads.append(fmt2("    {} = c.{}\n", copy fname, copy fname).as_str());
                    news.append(fname.as_str());
                },
            }
        }
        out.append(fmt2("\ndata class {}({})\n", copy n, move fields).as_str());
        out.append(fmt3("\ninternal fun {}.write(c: {}) {{\n{}}}\n", copy n, copy cn, move writes).as_str());
        out.append(fmt3("\ninternal fun {}.readFrom(c: {}) {{\n{}}}\n", copy n, copy cn, move reads).as_str());
        out.append(fmt3("\ninternal fun {}.toKotlin(): {} = {}(", copy cn, copy n, copy n).as_str());
        out.append(fmt("{})\n", move news).as_str());
        out.append(fmt3("\ninternal fun {}.toC(): CValue<{}> = cValue {{ this@toC.write(this) }}\n", copy n, copy cn, S("")).as_str());
    }
    // a class per export struct: AutoCloseable, and a Cleaner for when it's collected
    for (s&) in this.handles.items() {
        val cls = this.local(this.c.si(*s).name);
        val cn = fmt("cnames.structs.{}", this.c_named(this.c.si(*s).name, false));
        val fr = this.free_name(*s);
        out.append(fmt3("\n// what a {} holds, freed once (by close or the cleaner)\ninternal class {}_raw(var p: CPointer<{}>?) {{\n", copy cls, copy cls, copy cn).as_str());
        out.append(fmt2("    fun free() {{\n        p?.let {{ {}.{}(it) }}\n        p = null\n    }}\n}}\n", copy cp, copy fr).as_str());
        out.append(fmt3("\n/** export struct {}; close() (or the cleaner, once it's collected) frees it */\nclass {} internal constructor(h: CPointer<{}>) : AutoCloseable {{\n", S(this.c.si(*s).name), copy cls, copy cn).as_str());
        out.append(fmt2("    private val voltRaw = {}_raw(h)\n    private val voltCleaner = createCleaner(voltRaw) {{ it.free() }}\n\n    override fun close() = voltRaw.free()\n\n", copy cls, S("")).as_str());
        out.append(fmt2("    internal fun voltHandle(): CPointer<{}> = voltRaw.p ?: throw IllegalStateException(\"this {} is closed\")\n", copy cn, copy cls).as_str());
        var statics: std::string = {};
        for (e&) in ents.items() {
            if (e.free_of != null) {
                continue;
            }
            val m = this.member_of(e.f, *s) ?? continue;
            val info = this.c.fi(e.f);
            if (this.node_is_method(e.f, *s)) {
                out.append("\n");
                val head = fmt2("fun {}({{}}){} = run {{", kt_ident(m), this.kt_ret(info.ret));
                out.append((try this.kt_fn(e.f, 1, head.as_str(), false, "    ")).as_str());
            } else if (m == "new" && this.made_by(e.f, *s)) {
                // a constructor: make the handle, then the instance holding it
                var args: std::string = {};
                var names: std::string = {};
                for (k) in 0..info.params.len {
                    if (k > 0) {
                        args.append(", ");
                        names.append(", ");
                    }
                    args.append(fmt2("{}: {}", kt_ident(info.params.at(k).name), this.kt_ty(info.params.at(k).ty)).as_str());
                    names.append(kt_ident(info.params.at(k).name).as_str());
                }
                out.append("\n");
                out.append(this.kt_doc(e.f, "    ").as_str());
                out.append(fmt2("    constructor({}) : this(voltMake({}))\n", move args, move names).as_str());
                statics.append("\n");
                statics.append((try this.kt_fn(e.f, 0, fmt("private fun voltMake({{}}): CPointer<{}> = run {{", copy cn).as_str(), true, "        ")).as_str());
            } else {
                statics.append("\n");
                val head = fmt2("fun {}({{}}){} = run {{", kt_ident(m), this.kt_ret(info.ret));
                statics.append((try this.kt_fn(e.f, 0, head.as_str(), false, "        ")).as_str());
            }
        }
        if (statics.len() > 0) {
            out.append(fmt("\n    companion object {{{}    }\n", move statics).as_str());
        }
        out.append("}\n");
    }
    // the functions
    for (e&) in ents.items() {
        if (e.free_of != null || this.class_of(e.f) != null) {
            continue;
        }
        val info = this.c.fi(e.f);
        out.append("\n");
        val head = fmt2("fun {}({{}}){} = run {{", kt_ident(info.c_name), this.kt_ret(info.ret));
        out.append((try this.kt_fn(e.f, 0, head.as_str(), false, "")).as_str());
    }
    return out;
}

// ---------- Ruby: a C extension ----------
// A Ruby exception longjmps, so nothing malloc'd is held across one: temporaries are ALLOCV
// buffers (the GC frees them), callbacks run (and convert their result) under rb_protect, and their
// exception is raised again once the Volt call is back (an owned result freed first)

// a Ruby constant's name: vec2 is Vec2, math_error is MathError
fn rb_const(s: str) -> std::string {
    var out: std::string = {};
    var up = true;
    for (c) in s {
        if (c == '_') {
            up = true;
        } else if (up && c >= 'a' && c <= 'z') {
            out.push(c - 32);
            up = false;
        } else {
            out.push(c);
            up = false;
        }
    }
    return out;
}

// C statements reading Ruby value v into C lvalue c (simple types: numbers, bool, enums, error
// codes and structs of those); what (a C string expression) names it in the error raised
attach fn rb_get(this: bind&, t: u32, v: str, c: str, what: str) -> std::string {
    match (this.shape_of(t) ?? shape::VOID) {
        .BOOL => { return fmt3("{} = vr_bool({}, {});", S(c), S(v), S(what)); },
        .FLOAT(b) => { return fmt4("{} = ({})vr_num({}, {});", S(c), this.c_prim(t, false), S(v), S(what)); },
        .INT(k) => { return fmt4("{} = ({}){}, {});", S(c), this.c_prim(t, false), rb_int_call(k, v), S(what)); },
        .ENUM(e) => { return fmt4("{} = ({}){}, {});", S(c), this.c_prim(t, false), rb_int_call(this.c.ei(e).tag, v), S(what)); },
        .CODE => { return fmt3("{} = (uint32_t)vr_uint({}, UINT32_MAX, {});", S(c), S(v), S(what)); },
        .STRUCT(s) => { return fmt4("vr_get_{}({}, &{}, {});", this.node_sname(s), S(v), S(c), S(what)); },
        default => { return S("rb_raise(rb_eTypeError, \"unsupported\");"); },
    }
}

// the call reading an integer of kind k from v, up to its last argument (what)
fn rb_int_call(k: int_ty, v: str) -> std::string {
    match (k) {
        .I8 => { return fmt("vr_int({}, INT8_MIN, INT8_MAX", S(v)); },
        .I16 => { return fmt("vr_int({}, INT16_MIN, INT16_MAX", S(v)); },
        .I32 => { return fmt("vr_int({}, INT32_MIN, INT32_MAX", S(v)); },
        .U8 => { return fmt("vr_uint({}, UINT8_MAX", S(v)); },
        .U16 => { return fmt("vr_uint({}, UINT16_MAX", S(v)); },
        .U32 => { return fmt("vr_uint({}, UINT32_MAX", S(v)); },
        .U64 => { return fmt("vr_uint({}, UINT64_MAX", S(v)); },
        .USIZE => { return fmt("vr_uint({}, SIZE_MAX", S(v)); },
        .ISIZE => { return fmt("vr_int({}, PTRDIFF_MIN, PTRDIFF_MAX", S(v)); },
        default => { return fmt("vr_int({}, INT64_MIN, INT64_MAX", S(v)); },
    }
}

// an expression making the Ruby value of simple C value c (of type t)
attach fn rb_put(this: bind&, t: u32, c: str) -> std::string {
    match (this.shape_of(t) ?? shape::VOID) {
        .BOOL => { return fmt("({} ? Qtrue : Qfalse)", S(c)); },
        .FLOAT(b) => { return fmt("DBL2NUM((double)({}))", S(c)); },
        .STRUCT(s) => { return fmt2("vr_new_{}(&{})", this.node_sname(s), S(c)); },
        .INT(k) => {
            if (k.signed()) {
                return fmt("LL2NUM((long long)({}))", S(c));
            }
            return fmt("ULL2NUM((unsigned long long)({}))", S(c));
        },
        .ENUM(e) => { return fmt("LL2NUM((long long)({}))", S(c)); },
        default => { return fmt("ULL2NUM((unsigned long long)({}))", S(c)); },
    }
}

// one argument of an export fn: its C locals (decl), the statements filling them from argv (get),
// what the call passes (pass), what writes changes back (after), and a callback's vr_cb (cb)
struct rb_arg {
    decl: std::string = {};
    get: std::string = {};
    pass: std::string = {};
    after: std::string = {};
    cb: std::string = {};
}

attach fn rb_arg_of(this: bind&, t: u32, v: str, c: str, what: str, a: rb_arg&) -> compile_error!void {
    if (this.node_simple(t)) {
        a.decl = fmt2("{} {};", this.c_prim(t, false), S(c));
        a.get = this.rb_get(t, v, c, what);
        a.pass = S(c);
        return;
    }
    val h = this.lent_handle(t);
    if (h) {
        a.decl = fmt2("{}{};", spaced(this.handle_c(h, false)), S(c));
        a.get = fmt3("{} = vr_check_{}({});", S(c), this.node_sname(h), S(v));
        a.pass = S(c);
        return;
    }
    match (this.shape_of(t) ?? shape::VOID) {
        .STR => {
            a.decl = fmt("volt_str {};", S(c));
            a.get = fmt4("{}.ptr = (const uint8_t *)vr_str({}, &{}.len, {});", S(c), S(v), S(c), S(what));
            a.pass = S(c);
        },
        .CSTR => {
            a.decl = fmt("const char *{} = NULL;", S(c));
            a.get = fmt3("if (!NIL_P({})) {{ VALUE s_ = {}; {} = StringValueCStr(s_); }}", S(v), S(v), S(c));
            a.pass = S(c);
        },
        .PTR(x) => {
            if (x != VOID && this.node_simple(x)) {
                // a struct (or number) by reference: a copy goes in, and what Volt changed comes back
                val vv = fmt("{}_val", S(c));
                a.decl = fmt2("{} {};", this.c_prim(x, false), copy vv);
                var back: std::string = {};
                match (this.shape_of(x) ?? shape::VOID) {
                    .STRUCT(s) => { back = fmt3("vr_set_{}({}, &{});", this.node_sname(s), S(v), copy vv); },
                    default => {},
                }
                if (this.nullable_ptr(t)) {
                    a.decl.append(fmt(" bool {}_null;", S(c)).as_str());
                    a.get = fmt4("{}_null = NIL_P({}); if (!{}_null) {{ {} }}", S(c), S(v), S(c), this.rb_get(x, v, vv.as_str(), what));
                    a.pass = fmt2("({}_null ? NULL : &{})", S(c), copy vv);
                    if (back.len() > 0) {
                        a.after = fmt2("if (!{}_null) {{ {} }}", S(c), move back);
                    }
                } else {
                    a.get = this.rb_get(x, v, vv.as_str(), what);
                    a.pass = fmt("&{}", copy vv);
                    a.after = move back;
                }
                return;
            }
            a.decl = fmt2("{}{} = NULL;", spaced(this.c_prim(t, false)), S(c));
            a.get = fmt3("if (!NIL_P({})) {{ {} = vr_pointer({}); }}", S(v), S(c), S(v));
            a.pass = S(c);
        },
        .SLICE(x) => {
            if (!this.node_simple(x)) {
                return fail(NO_SPAN, fmt("a slice of {} can't come from Ruby (numbers, bool, enums and structs of those can)", this.c.ty_name(x)));
            }
            a.decl = fmt3("{} {}; VALUE {}_tmp = 0;", this.c_prim(t, false), S(c), S(c));
            a.get = fmt3("Check_Type({}, T_ARRAY); {}.len = (size_t)RARRAY_LEN({}); ", S(v), S(c), S(v));
            a.get.append(fmt3("{}.ptr = ALLOCV({}_tmp, sizeof *{}.ptr * ", S(c), S(c), S(c)).as_str());
            a.get.append(fmt2("({}.len ? {}.len : 1));", S(c), S(c)).as_str());
            a.get.append(fmt3(" for (size_t i = 0; i < {}.len; i++) {{ {} }}", S(c), this.rb_get(x, fmt("rb_ary_entry({}, (long)i)", S(v)).as_str(), fmt("{}.ptr[i]", S(c)).as_str(), what), S("")).as_str());
            a.pass = S(c);
            // what Volt wrote into the elements comes back
            a.after = fmt3("for (size_t i = 0; i < {}.len; i++) {{ rb_ary_store({}, (long)i, {}); }}", S(c), S(v), this.rb_put(x, fmt("{}.ptr[i]", S(c)).as_str()));
        },
        .OPT(x) => {
            if (!this.node_simple(x)) {
                return fail(NO_SPAN, fmt("an optional {} can't come from Ruby (numbers, bool, enums and structs of those can)", this.c.ty_name(x)));
            }
            a.decl = fmt2("{} {};", this.c_prim(t, false), S(c));
            a.get = fmt4("memset(&{}, 0, sizeof {}); if (!NIL_P({})) {{ {}.has = true; ", S(c), S(c), S(v), S(c));
            a.get.append(fmt("{} }", this.rb_get(x, v, fmt("{}.value", S(c)).as_str(), what)).as_str());
            a.pass = S(c);
        },
        .CLOSURE(i) => {
            a.decl = fmt("struct vr_cb {}_cb;", S(c));
            a.get = fmt3("{}_cb.fn = vr_callable({}); {}_cb.state = 0;", S(c), S(v), S(c));
            a.pass = fmt2("vr_cb{}, &{}_cb", unum(@cast<u64>(i)), S(c));
            a.cb = fmt("{}_cb", S(c));
        },
        default => { return fail(NO_SPAN, fmt("{} can't come from Ruby", this.c.ty_name(t))); },
    }
    return;
}

// an expression making the Ruby value of C result r (of type t); statements before it (pre) raise
// the result's error
attach fn rb_result(this: bind&, t: u32, r: str, pre: std::string&) -> compile_error!std::string {
    if (t == VOID) {
        return S("Qnil");
    }
    if (this.node_simple(t)) {
        return this.rb_put(t, r);
    }
    match (this.shape_of(t) ?? shape::VOID) {
        .STR => { return fmt2("rb_utf8_str_new((const char *){}.ptr, (long){}.len)", S(r), S(r)); },
        .CSTR => { return fmt2("({} ? rb_utf8_str_new_cstr({}) : Qnil)", S(r), S(r)); },
        .TEXT(x) => { return fmt("vr_take({})", S(r)); },
        .HANDLE(s) => { return fmt2("vr_wrap_{}({})", this.node_sname(s), S(r)); },
        .OPT(x) => {
            if (!this.node_simple(x)) {
                return fail(NO_SPAN, fmt("an optional {} can't go to Ruby", this.c.ty_name(x)));
            }
            return fmt2("({}.has ? {} : Qnil)", S(r), this.rb_put(x, fmt("{}.value", S(r)).as_str()));
        },
        .SLICE(x) => {
            if (!this.node_simple(x)) {
                return fail(NO_SPAN, fmt("a slice of {} can't go to Ruby", this.c.ty_name(x)));
            }
            pre.append(fmt3("    VALUE list = rb_ary_new_capa((long){}.len);\n    for (size_t i = 0; i < {}.len; i++) {{\n        rb_ary_push(list, {});\n    }}\n", S(r), S(r), this.rb_put(x, fmt("{}.ptr[i]", S(r)).as_str())).as_str());
            return S("list");
        },
        .RESULT(e, x) => {
            pre.append(fmt2("    if ({}.error != 0) {{\n        vr_raise({}.error);\n    }}\n", S(r), S(r)).as_str());
            return this.rb_result(x, fmt("{}.value", S(r)).as_str(), pre);
        },
        .PTR(x) => { return fmt2("({} ? vr_from_pointer((void *){}) : Qnil)", S(r), S(r)); },
        default => { return fail(NO_SPAN, fmt("{} can't go to Ruby", this.c.ty_name(t))); },
    }
}

// what frees owned C result r (of type t) when a callback's exception is raised instead
attach fn rb_drop(this: bind&, t: u32, r: str) -> std::string {
    match (this.shape_of(t) ?? shape::VOID) {
        .TEXT(x) => { return fmt("volt_text_free({}); ", S(r)); },
        .HANDLE(s) => { return fmt2("{}({}); ", this.free_name(s), S(r)); },
        .RESULT(e, x) => {
            val inner = this.rb_drop(x, fmt("{}.value", S(r)).as_str());
            if (inner.len() == 0) {
                return {};
            }
            return fmt2("if ({}.error == 0) {{ {}}} ", S(r), move inner);
        },
        default => { return {}; },
    }
}

// the C function behind one Ruby method (self_first: an instance method, whose self is the first
// parameter); it takes argc/argv, so the last callback can be a block
attach fn rb_fn(this: bind&, f: u32, self_first: bool, out: std::string&) -> compile_error!void {
    val info = this.c.fi(f);
    var first: usize = 0;
    if (self_first) {
        first = 1;
    }
    var decls: std::string = {};
    var gets: std::string = {};
    var passes: std::string = {};
    var afters: std::string = {};
    var raises: std::string = {};
    val drop = this.rb_drop(info.ret, "r");
    val n = info.params.len - first;
    var block_last = false;
    if (n > 0) {
        match (this.shape_of(info.params.at(info.params.len - 1).ty) ?? shape::VOID) {
            .CLOSURE(i) => { block_last = true; },
            default => {},
        }
    }
    for (k) in 0..info.params.len {
        val p = info.params.at(k);
        var a: rb_arg = {};
        var v = S("self");
        if (k >= first) {
            v = fmt("argv[{}]", unum(@cast<u64>(k - first)));
        }
        val what = fmt2("\"argument {} of {}\"", S(p.name), S(info.c_name));
        val cname = fmt("p_{}", S(p.name));
        try this.rb_arg_of(p.ty, v.as_str(), cname.as_str(), what.as_str(), &a);
        decls.append(fmt("    {}\n", copy a.decl).as_str());
        gets.append(fmt("    {}\n", copy a.get).as_str());
        if (passes.len() > 0) {
            passes.append(", ");
        }
        passes.append(a.pass.as_str());
        if (a.after.len() > 0) {
            afters.append(fmt("    {}\n", copy a.after).as_str());
        }
        if (a.cb.len() > 0) {
            raises.append(fmt3("    if ({}.state) {{\n        {}rb_jump_tag({}.state);\n    }}\n", copy a.cb, copy drop, copy a.cb).as_str());
        }
    }
    out.append(fmt("\nstatic VALUE vr_f_{}(int argc, VALUE *argv, VALUE self) {{\n", S(info.c_name)).as_str());
    if (n == 0) {
        out.append("    (void)argv;\n");
    }
    if (!self_first) {
        out.append("    (void)self;\n");
    }
    if (block_last) {
        // the last callback can be a block
        out.append(fmt3("    VALUE args[{}];\n    if (argc == {} && rb_block_given_p()) {{\n", unum(@cast<u64>(n)), unum(@cast<u64>(n - 1)), S("")).as_str());
        out.append(fmt3("        for (int i = 0; i < argc; i++) {{\n            args[i] = argv[i];\n        }}\n        args[{}] = rb_block_proc();\n        argc = {};\n        argv = args;\n    }}\n", unum(@cast<u64>(n - 1)), unum(@cast<u64>(n)), S("")).as_str());
    }
    out.append(fmt2("    rb_check_arity(argc, {}, {});\n", unum(@cast<u64>(n)), unum(@cast<u64>(n))).as_str());
    out.append(decls.as_str());
    out.append(gets.as_str());
    val call = fmt2("{}({})", S(info.c_name), move passes);
    if (info.ret == VOID) {
        out.append(fmt("    {};\n", move call).as_str());
    } else {
        out.append(fmt2("    {}r = {};\n", spaced(this.c_prim(info.ret, false)), move call).as_str());
    }
    // a callback's exception first, then the result (or its error), then what Volt changed comes back
    out.append(raises.as_str());
    var pre: std::string = {};
    val res = try this.rb_result(info.ret, "r", &pre);
    out.append(pre.as_str());
    out.append(fmt("    VALUE result = {};\n", copy res).as_str());
    out.append(afters.as_str());
    out.append("    return result;\n}\n");
    return;
}

attach fn rb_text(this: bind&) -> compile_error!std::string {
    val ents = this.entries();
    val p = this.pkg;
    val mod = rb_const(p);
    var out = fmt("// {}: generated by voltc bindings; a Ruby C extension for the Volt package. Build it\n", S(p));
    out.append(fmt3("// against the library and Ruby's headers:\n//   cc -shared -fPIC -I<rubyhdrdir> -I<rubyarchhdrdir> {}_ruby.c -L. -l{} -o {}.so\n", S(p), S(p), S(p)).as_str());
    out.append(fmt3("// then require \"{}\": module {}. Errors are raised as {}::Error, one subclass per error set.\n#include <ruby.h>\n#include <stdint.h>\n#include <stdio.h>\n#include <string.h>\n\n", S(p), copy mod, copy mod).as_str());
    out.append(this.c_text().as_str());
    out.append(fmt("\nstatic VALUE vr_module, vr_error;\n", S("")).as_str());
    out.append("\n// ---------- conversions: each raises naming what didn't fit ----------\n\n");
    out.append("static inline long long vr_int(VALUE v, long long lo, long long hi, const char *what) {\n    if (!RB_INTEGER_TYPE_P(v)) {\n        rb_raise(rb_eTypeError, \"%s: expected an Integer, got %\" PRIsVALUE, what, rb_obj_class(v));\n    }\n    long long x = NUM2LL(v);\n    if (x < lo || x > hi) {\n        rb_raise(rb_eRangeError, \"%s: %lld doesn't fit\", what, x);\n    }\n    return x;\n}\n\n");
    out.append("static inline unsigned long long vr_uint(VALUE v, unsigned long long hi, const char *what) {\n    if (!RB_INTEGER_TYPE_P(v)) {\n        rb_raise(rb_eTypeError, \"%s: expected an Integer, got %\" PRIsVALUE, what, rb_obj_class(v));\n    }\n    if (RTEST(rb_funcall(v, '<', 1, INT2FIX(0)))) {\n        rb_raise(rb_eRangeError, \"%s: %\" PRIsVALUE \" is negative\", what, v);\n    }\n    unsigned long long x = NUM2ULL(v);\n    if (x > hi) {\n        rb_raise(rb_eRangeError, \"%s: %llu doesn't fit\", what, x);\n    }\n    return x;\n}\n\n");
    out.append("static inline double vr_num(VALUE v, const char *what) {\n    if (!RB_FLOAT_TYPE_P(v) && !RB_INTEGER_TYPE_P(v)) {\n        rb_raise(rb_eTypeError, \"%s: expected a number, got %\" PRIsVALUE, what, rb_obj_class(v));\n    }\n    return NUM2DBL(v);\n}\n\n");
    out.append("static inline bool vr_bool(VALUE v, const char *what) {\n    if (v != Qtrue && v != Qfalse) {\n        rb_raise(rb_eTypeError, \"%s: expected true or false, got %\" PRIsVALUE, what, rb_obj_class(v));\n    }\n    return v == Qtrue;\n}\n\n");
    out.append("// a String's bytes (the String stays on the caller's stack for the call)\nstatic inline const char *vr_str(VALUE v, size_t *len, const char *what) {\n    if (!RB_TYPE_P(v, T_STRING)) {\n        rb_raise(rb_eTypeError, \"%s: expected a String, got %\" PRIsVALUE, what, rb_obj_class(v));\n    }\n    *len = (size_t)RSTRING_LEN(v);\n    return RSTRING_PTR(v);\n}\n\n");
    out.append("// a struct's field, from a Struct (or anything with the reader) or a Hash\nstatic inline VALUE vr_field(VALUE v, const char *name) {\n    if (RB_TYPE_P(v, T_HASH)) {\n        return rb_hash_aref(v, ID2SYM(rb_intern(name)));\n    }\n    return rb_funcall(v, rb_intern(name), 0);\n}\n\nstatic inline void vr_set_field(VALUE v, const char *name, VALUE x) {\n    if (RB_TYPE_P(v, T_HASH)) {\n        rb_hash_aset(v, ID2SYM(rb_intern(name)), x);\n    } else {\n        char setter[128];\n        snprintf(setter, sizeof setter, \"%s=\", name);\n        rb_funcall(v, rb_intern(setter), 1, x);\n    }\n}\n\n");
    out.append(fmt("// a pointer from another call (an opaque object)\nstatic VALUE vr_cPointer;\nstatic const rb_data_type_t vr_type_pointer = {{.wrap_struct_name = \"{}::Pointer\", .flags = RUBY_TYPED_FREE_IMMEDIATELY}};\n\nstatic inline VALUE vr_from_pointer(void *p) {{\n    return TypedData_Wrap_Struct(vr_cPointer, &vr_type_pointer, p);\n}}\n\nstatic inline void *vr_pointer(VALUE v) {{\n    return rb_check_typeddata(v, &vr_type_pointer);\n}}\n", copy mod).as_str());
    if (this.texts.len > 0) {
        out.append("\n// owned text: a String, and the text freed\nstatic inline VALUE vr_take(volt_text t) {\n    VALUE s = rb_utf8_str_new((const char *)t.ptr, (long)t.len);\n    volt_text_free(t);\n    return s;\n}\n");
    }
    // errors: Mod::Error (code, and the name as the message) and a subclass per error set
    out.append("\nstatic inline const char *vr_error_name(uint32_t code) {\n    switch (code) {\n");
    for (c&) in this.all_codes().items() {
        out.append(fmt2("    case {}u: return \"{}\";\n", num(c.code), S(c.name)).as_str());
    }
    out.append("    }\n    return \"error\";\n}\n\nstatic inline VALUE vr_error_class(uint32_t code);\n\n// raises the exception for a Volt error code\nstatic inline void vr_raise(uint32_t code) {\n    VALUE e = rb_exc_new_cstr(vr_error_class(code), vr_error_name(code));\n    rb_iv_set(e, \"@code\", UINT2NUM(code));\n    rb_exc_raise(e);\n}\n");
    var classes: std::string = {};
    for (et&) in this.codes.items() {
        match (*this.c.t.get(*et)) {
            .ENUM(e) => { classes.append(fmt("static VALUE vr_error_{};\n", this.local(this.c.ei(e).name)).as_str()); },
            default => {},
        }
    }
    out.append(fmt("\n{}\nstatic inline VALUE vr_error_class(uint32_t code) {{\n    switch (code) {{\n", move classes).as_str());
    for (c&) in this.all_codes().items() {
        out.append(fmt2("    case {}u: return vr_error_{};\n", num(c.code), copy c.set).as_str());
    }
    out.append("    }\n    return vr_error;\n}\n");
    // structs: Struct classes (a Hash with the fields works too)
    for (s&) in this.structs.items() {
        if (!this.node_simple(this.c.t.intern(tyk::STRUCT(*s)))) {
            continue;
        }
        val sn = this.node_sname(*s);
        val cn = this.c_named(this.c.si(*s).name, false);
        out.append(fmt2("\nstatic VALUE vr_class_{};\n\nstatic inline void vr_get_{}(VALUE v, ", copy sn, copy sn).as_str());
        out.append(fmt("{} *out, const char *what) {{\n    (void)what;\n", copy cn).as_str());
        for (f&) in this.c.si(*s).fields.items() {
            val fw = fmt2("\"field {} of {}\"", S(f.name), copy sn);
            out.append(fmt3("    {{\n        VALUE f = vr_field(v, \"{}\");\n        {}\n    }}\n", S(f.name), this.rb_get(f.ty, "f", fmt("out->{}", S(f.name)).as_str(), fw.as_str()), S("")).as_str());
        }
        out.append("}\n");
        out.append(fmt2("\nstatic inline void vr_set_{}(VALUE v, const {} *in) {{\n", copy sn, copy cn).as_str());
        for (f&) in this.c.si(*s).fields.items() {
            out.append(fmt2("    vr_set_field(v, \"{}\", {});\n", S(f.name), this.rb_put(f.ty, fmt("in->{}", S(f.name)).as_str())).as_str());
        }
        out.append("}\n");
        out.append(fmt2("\nstatic inline VALUE vr_new_{}(const {} *in) {{\n", copy sn, copy cn).as_str());
        out.append(fmt("    VALUE args[{}];\n", unum(@cast<u64>(this.c.si(*s).fields.len))).as_str());
        var k: usize = 0;
        for (f&) in this.c.si(*s).fields.items() {
            out.append(fmt2("    args[{}] = {};\n", unum(@cast<u64>(k)), this.rb_put(f.ty, fmt("in->{}", S(f.name)).as_str())).as_str());
            k += 1;
        }
        out.append(fmt2("    return rb_class_new_instance({}, args, vr_class_{});\n}\n", unum(@cast<u64>(k)), copy sn).as_str());
    }
    // callbacks: run (with the result converted) under rb_protect; the first exception is kept and
    // the later calls skipped
    if (this.closures.len > 0) {
        out.append("\n// a Proc passed for a callback, and the state of the exception it raised\nstruct vr_cb {\n    VALUE fn;\n    int state;\n};\n\nstatic inline VALUE vr_callable(VALUE v) {\n    if (!rb_respond_to(v, rb_intern(\"call\"))) {\n        rb_raise(rb_eTypeError, \"expected a Proc (or a block)\");\n    }\n    return v;\n}\n");
    }
    for (i) in 0..this.closures.len {
        match (*this.c.t.get(*this.closures.at(i))) {
            .FN_VAL(ps&, r) => {
                val n = unum(@cast<u64>(i));
                out.append(fmt2("\nstruct vr_run{} {{\n    VALUE fn;\n    VALUE argv[{}];\n", copy n, unum(@cast<u64>(ps.len + 1))).as_str());
                if (r != VOID) {
                    if (!this.node_simple(r)) {
                        return fail(NO_SPAN, fmt("a callback returning {} can't call Ruby", this.c.ty_name(r)));
                    }
                    out.append(fmt("    {}out;\n", spaced(this.c_prim(r, false))).as_str());
                }
                out.append(fmt3("}};\n\nstatic VALUE vr_run{}(VALUE arg) {{\n    struct vr_run{} *a = (struct vr_run{} *)arg;\n", copy n, copy n, copy n).as_str());
                out.append(fmt("    VALUE ret = rb_funcallv(a->fn, rb_intern(\"call\"), {}, a->argv);\n", unum(@cast<u64>(ps.len))).as_str());
                if (r != VOID) {
                    out.append(fmt("    {}\n", this.rb_get(r, "ret", "a->out", "\"the callback's result\"")).as_str());
                } else {
                    out.append("    (void)ret;\n");
                }
                out.append("    return Qnil;\n}\n");
                var params = S("void *user");
                for (k) in 0..ps.len {
                    params.append(fmt2(", {}a{}", spaced(this.c_prim(*ps.at(k), false)), unum(@cast<u64>(k))).as_str());
                }
                out.append(fmt3("\nstatic {}vr_cb{}({}) {{\n    struct vr_cb *c = user;\n", spaced(this.c_prim(r, false)), copy n, move params).as_str());
                out.append(fmt2("    struct vr_run{} a;\n    memset(&a, 0, sizeof a);\n    a.fn = c->fn;\n", copy n, S("")).as_str());
                for (k) in 0..ps.len {
                    val ak = fmt("a{}", unum(@cast<u64>(k)));
                    match (this.shape_of(*ps.at(k)) ?? shape::VOID) {
                        .STR => { out.append(fmt3("    a.argv[{}] = rb_utf8_str_new((const char *){}.ptr, (long){}.len);\n", unum(@cast<u64>(k)), copy ak, copy ak).as_str()); },
                        default => {
                            if (!this.node_simple(*ps.at(k))) {
                                return fail(NO_SPAN, fmt("a callback taking {} can't call Ruby", this.c.ty_name(*ps.at(k))));
                            }
                            out.append(fmt2("    a.argv[{}] = {};\n", unum(@cast<u64>(k)), this.rb_put(*ps.at(k), ak.as_str())).as_str());
                        },
                    }
                }
                out.append(fmt("    if (!c->state) {{\n        rb_protect(vr_run{}, (VALUE)&a, &c->state);\n    }}\n", copy n).as_str());
                if (r != VOID) {
                    out.append("    return a.out;\n");
                }
                out.append("}\n");
            },
            default => {},
        }
    }
    // classes: a TypedData object holding the handle (NULL once closed)
    for (s&) in this.handles.items() {
        val sn = this.node_sname(*s);
        val cn = this.handle_c(*s, false);
        out.append(fmt3("\n// export struct {}\nstatic VALUE vr_class_{};\n\nstatic void vr_dfree_{}(void *h) {{\n", S(this.c.si(*s).name), copy sn, copy sn).as_str());
        out.append(fmt("    if (h) {{\n        {}(h);\n    }}\n}}\n", this.free_name(*s)).as_str());
        out.append(fmt4("\nstatic const rb_data_type_t vr_type_{} = {{.wrap_struct_name = \"{}::{}\", .function = {{.dfree = vr_dfree_{}}}, .flags = RUBY_TYPED_FREE_IMMEDIATELY}};\n", copy sn, copy mod, rb_const(sn.as_str()), copy sn).as_str());
        out.append(fmt4("\nstatic inline {}vr_check_{}(VALUE v) {{\n    {}h = rb_check_typeddata(v, &vr_type_{});\n", spaced(copy cn), copy sn, spaced(copy cn), copy sn).as_str());
        out.append(fmt("    if (!h) {{\n        rb_raise(rb_eRuntimeError, \"this {} is closed\");\n    }}\n    return h;\n}}\n", copy sn).as_str());
        out.append(fmt4("\nstatic inline VALUE vr_wrap_{}({}h) {{\n    return TypedData_Wrap_Struct(vr_class_{}, &vr_type_{}, h);\n}}\n", copy sn, spaced(copy cn), copy sn, copy sn).as_str());
        out.append(fmt3("\n// close: frees the handle now (otherwise the GC does)\nstatic VALUE vr_close_{}(VALUE self) {{\n    void *h = rb_check_typeddata(self, &vr_type_{});\n    if (h) {{\n        {}(h);\n", copy sn, copy sn, this.free_name(*s)).as_str());
        out.append("        DATA_PTR(self) = NULL;\n    }\n    return Qnil;\n}\n");
    }
    // the functions
    for (e&) in ents.items() {
        if (e.free_of != null) {
            continue;
        }
        val cls = this.class_of(e.f);
        var method = false;
        if (cls) {
            method = this.node_is_method(e.f, cls);
        }
        try this.rb_fn(e.f, method, &out);
    }
    // Init: the module, its functions, enums and error sets (modules of constants), structs and classes
    out.append(fmt3("\nRUBY_FUNC_EXPORTED void Init_{}(void) {{\n    vr_module = rb_define_module(\"{}\");\n    vr_error = rb_define_class_under(vr_module, \"Error\", rb_eStandardError);\n    rb_define_attr(vr_error, \"code\", 1, 0);\n", S(p), copy mod, S("")).as_str());
    out.append("    vr_cPointer = rb_define_class_under(vr_module, \"Pointer\", rb_cObject);\n    rb_undef_alloc_func(vr_cPointer);\n");
    for (et&) in this.codes.items() {
        match (*this.c.t.get(*et)) {
            .ENUM(e) => {
                val info = this.c.ei(e);
                val ln = this.local(info.name);
                out.append(fmt2("    vr_error_{} = rb_define_class_under(vr_module, \"{}\", vr_error);\n", copy ln, rb_const(ln.as_str())).as_str());
                for (i) in 0..info.names.len {
                    out.append(fmt3("    rb_define_const(vr_error_{}, \"{}\", UINT2NUM({}u));\n", copy ln, S(*info.names.at(i)), num(*info.values.at(i))).as_str());
                }
            },
            default => {},
        }
    }
    for (en&) in this.enums.items() {
        val info = this.c.ei(*en);
        out.append(fmt("    {\n        VALUE m = rb_define_module_under(vr_module, \"{}\");\n", rb_const(this.local(info.name).as_str())).as_str());
        for (i) in 0..info.names.len {
            out.append(fmt2("        rb_define_const(m, \"{}\", LL2NUM({}));\n", S(*info.names.at(i)), num(*info.values.at(i))).as_str());
        }
        out.append("    }\n");
    }
    for (s&) in this.structs.items() {
        if (!this.node_simple(this.c.t.intern(tyk::STRUCT(*s)))) {
            continue;
        }
        val sn = this.node_sname(*s);
        var members: std::string = {};
        for (f&) in this.c.si(*s).fields.items() {
            members.append(fmt(", ID2SYM(rb_intern(\"{}\"))", S(f.name)).as_str());
        }
        out.append(fmt3("    vr_class_{} = rb_funcall(rb_cStruct, rb_intern(\"new\"), {}{});\n", copy sn, unum(@cast<u64>(this.c.si(*s).fields.len)), move members).as_str());
        out.append(fmt2("    rb_define_const(vr_module, \"{}\", vr_class_{});\n", rb_const(sn.as_str()), copy sn).as_str());
    }
    for (e&) in ents.items() {
        if (e.free_of != null || this.class_of(e.f) != null) {
            continue;
        }
        val n = S(this.c.fi(e.f).c_name);
        out.append(fmt2("    rb_define_module_function(vr_module, \"{}\", vr_f_{}, -1);\n", copy n, copy n).as_str());
    }
    for (s&) in this.handles.items() {
        val sn = this.node_sname(*s);
        out.append(fmt2("    vr_class_{} = rb_define_class_under(vr_module, \"{}\", rb_cObject);\n", copy sn, rb_const(sn.as_str())).as_str());
        out.append(fmt3("    rb_undef_alloc_func(vr_class_{});\n    rb_define_method(vr_class_{}, \"close\", vr_close_{}, 0);\n", copy sn, copy sn, copy sn).as_str());
        for (e&) in ents.items() {
            if (e.free_of != null) {
                continue;
            }
            val m = this.member_of(e.f, *s) ?? continue;
            if (this.node_is_method(e.f, *s)) {
                out.append(fmt3("    rb_define_method(vr_class_{}, \"{}\", vr_f_{}, -1);\n", copy sn, S(m), S(this.c.fi(e.f).c_name)).as_str());
            } else {
                out.append(fmt3("    rb_define_singleton_method(vr_class_{}, \"{}\", vr_f_{}, -1);\n", copy sn, S(m), S(this.c.fi(e.f).c_name)).as_str());
            }
        }
    }
    out.append("}\n");
    return out;
}

// ---------- the command ----------

// the bindings of package pkg in lang (see the top of the file; node, js and ts are a Node-API
// addon, its loader and its types; json is the model itself)
attach fn bindings(this: checker&, pkg: str, lang: str) -> compile_error!std::string {
    var b: bind = { c: this, pkg: pkg, wide: lang == "c" || lang == "cpp" || lang == "rust" || lang == "zig" || lang == "json" };
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
    if (lang == "pyi") {
        return b.pyi_text();
    }
    if (lang == "csharp") {
        return b.cs_text();
    }
    if (lang == "java") {
        return b.java_text();
    }
    if (lang == "go") {
        return b.go_text();
    }
    if (lang == "json") {
        return b.json_text();
    }
    if (lang == "lua") {
        return b.lua_text();
    }
    if (lang == "dart") {
        return b.dart_text();
    }
    if (lang == "swift") {
        return b.swift_text();
    }
    if (lang == "kotlin") {
        return b.kt_text();
    }
    if (lang == "ruby") {
        return b.rb_text();
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
    return fail(NO_SPAN, fmt("--lang takes c, cpp, rust, zig, python, pyi, csharp, java, go, lua, dart, swift, kotlin, ruby, node, js, ts or json, not '{}'", S(lang)));
}
