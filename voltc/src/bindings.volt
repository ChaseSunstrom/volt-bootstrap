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
// - owned elements (std::vec<T>), returned as a list: the elements as C sees them (text as a lent
//   str, a handle as a pointer the caller owns), how many, and what frees them (the list, not the
//   handles); as a parameter, a slice of those (Volt copies them; handles are given up);
// - a slice of text or handles, as a slice of str or of the handles' pointers (lent); an optional
//   text or handle: as a parameter a str? or a pointer (null: none), as a result an optional of
//   volt_text or a pointer the caller owns;
// - a closure parameter fn(A) -> R: a C function taking the caller's data first, and that data.
// The last five differ from how Volt passes them, so voltc lib adds shims (see shims below), and
// relays for languages that can't make a C function giving a struct (Python's ctypes; see by_out).
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
    LIST: u32,         // owned elements: the Volt type (std::vec<T>)
}

// what can sit inside another type's C form (a field, an element, a fn pointer's parameter): not the
// shapes that only work at the edge of an export fn
// the languages whose bindings take every shape (bind.wide), as messages name them
fn wide_langs() -> std::string {
    return S("C, C++, Rust, Zig, Go, Python, Java, C#, JavaScript and Lua");
}

fn plain(s: shape) -> bool {
    match (s) {
        .TEXT(t) => { return false; },
        .HANDLE(h) => { return false; },
        .CLOSURE(c) => { return false; },
        .OPT(t) => { return false; },
        .TRAIT(t) => { return false; },
        .LIST(t) => { return false; },
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
    lists: std::vec<u32> = {};    // owned element types (std::vec<T>)
    // the struct, optional and E!T types C holds by value, each after what it holds (the order C
    // declares them in)
    layout: std::vec<u32> = {};
    // the shapes only the wide languages (wide_langs) take (traits, closures given out or taking text and
    // handles, owned values as parameters, lists): false for the other languages' generators
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
    if (!plain(s) || this.converted(t)) {
        return this.no_form(t);
    }
    return s;
}

// is t a slice whose elements cross converted (text, handles), which only an export fn's parameter
// takes?
attach fn converted(this: bind&, t: u32) -> bool {
    val e = this.slice_elem(t);
    return e != VOID && this.view_of(e) != e;
}

// what a slice's or a list's element is to C, lent: text is its str, a handle its pointer, anything
// else itself
attach fn view_of(this: bind&, t: u32) -> u32 {
    match (this.shape_of(t) ?? shape::VOID) {
        .TEXT(x) => { return STR; },
        .HANDLE(h) => { return this.c.t.intern(tyk::REF(t)); },
        default => { return t; },
    }
}

// a slice's or a list's element: what sits inside other types, text and handles (lent, see
// view_of), and optionals of what sits inside
attach fn elem(this: bind&, t: u32) -> shape? {
    val s = this.shape_of(t) ?? return null;
    match (s) {
        .TEXT(x) => {
            // converted at the edge (not in other languages yet)
            if (!this.wide) {
                return this.no_form(t);
            }
            this.uses_str = true;
            return s;
        },
        .HANDLE(h) => {
            if (!this.wide) {
                return this.no_form(t);
            }
            this.shape_of(this.view_of(t)) ?? return null;
            return s;
        },
        .OPT(x) => {
            if (plain(this.shape_of(x) ?? shape::VOID) && !this.converted(x)) {
                return s;
            }
            return this.no_form(t);
        },
        default => {},
    }
    if (!plain(s) || this.converted(t)) {
        return this.no_form(t);
    }
    return s;
}

// the type whose C form t takes as an export fn's parameter: text as str, a list as a slice of its
// elements' views, an optional text as str?, an optional handle as its pointer
attach fn in_ty(this: bind&, t: u32) -> u32 {
    match (this.shape_of(t) ?? shape::VOID) {
        .TEXT(x) => { return STR; },
        .LIST(x) => { return this.c.t.intern(tyk::SLICE(this.view_of(this.list_elem(t)))); },
        .OPT(x) => {
            match (this.shape_of(x) ?? shape::VOID) {
                .TEXT(y) => { return this.c.t.intern(tyk::OPT(STR)); },
                .HANDLE(h) => { return this.c.t.intern(tyk::REF(x)); },
                default => {},
            }
        },
        default => {},
    }
    return t;
}

// is s an optional whose value is converted (text, a handle)?
attach fn opt_owned(this: bind&, s: shape) -> bool {
    match (s) {
        .OPT(x) => {
            match (this.shape_of(x) ?? shape::VOID) {
                .TEXT(y) => { return true; },
                .HANDLE(h) => { return true; },
                default => {},
            }
        },
        default => {},
    }
    return false;
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

// is struct s a list (std::vec: other languages get its elements, through its items())?
attach fn is_list(this: bind&, s: u32) -> bool {
    return starts_with(this.c.ty_name(this.c.t.intern(tyk::STRUCT(s))).as_str(), "std::vec<");
}

// a slice type's element (its shape holds the element's view, see view_of)
attach fn slice_elem(this: bind&, t: u32) -> u32 {
    match (*this.c.t.get(t)) {
        .SLICE(e) => { return e; },
        default => { return VOID; },
    }
}

// the export struct an element is a handle of (by value, or lent as T& or T*), if it is one
attach fn handle_of(this: bind&, e: u32) -> u32? {
    match (this.shape_of(e) ?? shape::VOID) {
        .HANDLE(h) => { return h; },
        default => { return this.lent_handle(e); },
    }
}

// a list type's element type (its first type argument)
attach fn list_elem(this: bind&, t: u32) -> u32 {
    match (*this.c.t.get(t)) {
        .STRUCT(s) => {
            match (*this.c.si(s).args.at(0)) {
                .TY(e) => { return e; },
                default => {},
            }
        },
        default => {},
    }
    return VOID;
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
            // an optional text or handle (converted at the edge; not in other languages yet)
            match (this.shape_of(x) ?? return null) {
                .TEXT(y) => {
                    if (!this.wide) {
                        return this.no_form(t);
                    }
                    this.uses_str = true;
                    this.shape_of(this.c.t.intern(tyk::OPT(STR))) ?? return null;
                    add_u32(&this.opts, x);
                    add_u32(&this.layout, t);
                    return shape::OPT(x);
                },
                .HANDLE(h) => {
                    if (!this.wide) {
                        return this.no_form(t);
                    }
                    this.shape_of(this.c.t.intern(tyk::REF(x))) ?? return null;
                    return shape::OPT(x);
                },
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
            // text and handles cross as their views (str, the handle's pointer), converted at the edge
            this.elem(elem) ?? return null;
            val v = this.view_of(elem);
            add_u32(&this.slices, v);
            return shape::SLICE(v);
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
            if (this.is_list(s) && !this.is_export_struct(s)) {
                // owned elements: a list out, a slice of their views in (not in other languages yet)
                if (!this.wide) {
                    return this.no_form(t);
                }
                val e = this.list_elem(t);
                this.elem(e) ?? return null;
                val v = this.view_of(e);
                add_u32(&this.slices, v);
                add_u32(&this.lists, t);
                return shape::LIST(t);
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
    if (!plain(s) || this.converted(t)) {
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
            .LIST(y) => { return this.no_form(x); },
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
    return with_help(fail(at, move msg), fmt("bindings take numbers, bool, pointers and references, cstr, str, slices, optionals, structs of those, plain enums, error sets, E!T, extern \"C\" fns, closures as parameters, and structs held by handles and owned text (@export_text) as results; {} take traits, owned values as parameters, closures given back, lists (std::vec), and optional text and handles too", wide_langs()));
}

// is a shape owned when it comes out of Volt (text, a handle by value, a closure, a trait's object),
// directly or as E!T's value?
attach fn owned_result(this: bind&, s: shape) -> bool {
    match (s) {
        .TEXT(t) => { return true; },
        .HANDLE(h) => { return true; },
        .CLOSURE(c) => { return true; },
        .TRAIT(x) => { return true; },
        .LIST(x) => { return true; },
        .OPT(x) => { return this.opt_owned(s); },
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
                .LIST(x) => { owned = true; },
                .OPT(x) => { owned = this.opt_owned(s); },
                .RESULT(e, x) => {
                    if (this.owned_result(s)) {
                        return fail(at, fmt3("export fn {}: its parameter {} is {}, which only comes out of export fns", S(f.name), S(p.name), this.c.ty_name(p.ty)));
                    }
                },
                default => {},
            }
            if (owned && !this.wide) {
                return with_help(fail(at, fmt3("export fn {}: its parameter {} is {}, which this language's bindings only take as a result", S(f.name), S(p.name), this.c.ty_name(p.ty))), fmt("take an export struct as X& (or X*) and text as str; {} bindings take owned values too", wide_langs()));
            }
        }
        val r = this.shape_of(f.ret) ?? return this.no_c_form(at, fmt("export fn {}: its return type", S(f.name)), f.ret);
        if (this.converted(f.ret)) {
            return with_help(fail(at, fmt2("export fn {}: it returns {}, a slice of what crosses converted, which nothing would own", S(f.name), this.c.ty_name(f.ret))), S("return a std::vec of them: it crosses as a list the caller frees"));
        }
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
                    return fail(at, fmt3("export fn {}: it returns {}, and this language's bindings only take closures as parameters ({} take them back too)", S(f.name), this.c.ty_name(f.ret), wide_langs()));
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

// does an export fn take a slice of text or handles (which C++ passes from a std::vector)?
attach fn converts_slices(this: bind&) -> bool {
    for (i&) in this.exports().items() {
        for (p&) in this.c.fi(*i).params.items() {
            if (this.converted(p.ty)) {
                return true;
            }
        }
    }
    return false;
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
            .LIST(x) => { return true; },
            .OPT(x) => {
                if (this.opt_owned(shape::OPT(x))) {
                    return true;
                }
            },
            default => {},
        }
        if (this.converted(p.ty)) {
            return true;
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
        .LIST(x) => { return fmt2("give_list_{}({})", index_of(&this.lists, t), move v); },
        .OPT(x) => {
            match (this.shape_of(x) ?? shape::VOID) {
                .TEXT(y) => { return fmt2("give_opt_text_{}({})", index_of(&this.texts, x), move v); },
                .HANDLE(h) => { return fmt2("opt_own_{}({})", index_of(&this.handles, h), move v); },
                default => {},
            }
            return v;
        },
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
        .LIST(x) => { return fmt2("unlist_{}({})", index_of(&this.lists, t), move v); },
        .OPT(x) => {
            match (this.shape_of(x) ?? shape::VOID) {
                .TEXT(y) => { return fmt2("opt_in_{}({})", index_of(&this.texts, x), move v); },
                .HANDLE(h) => { return fmt2("opt_take_{}({})", index_of(&this.handles, h), move v); },
                default => {},
            }
            return v;
        },
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
        .LIST(x) => {
            if (result) {
                return fmt("list_{}", index_of(&this.lists, t));
            }
            return fmt("{}[..]", this.view_src(this.list_elem(t)));
        },
        .OPT(x) => {
            match (this.shape_of(x) ?? shape::VOID) {
                .TEXT(y) => {
                    if (result) {
                        return fmt("opt_text_{}", index_of(&this.texts, x));
                    }
                    return S("str?");
                },
                .HANDLE(h) => { return fmt("({}*)", this.src(x)); },
                default => {},
            }
        },
        default => {},
    }
    if (this.converted(t)) {
        return fmt("{}[..]", this.view_src(this.slice_elem(t)));
    }
    return this.src(t);
}

// a slice's or a list's element as C sees it, as Volt source: text as str, a handle as its pointer
attach fn view_src(this: bind&, t: u32) -> std::string {
    match (this.shape_of(t) ?? shape::VOID) {
        .TEXT(x) => { return S("str"); },
        .HANDLE(h) => { return fmt("({}*)", this.src(t)); },
        default => { return this.src(t); },
    }
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
                if (this.converted(p.ty)) {
                    // the elements as Volt holds them, made for the call: text copied, handles' values
                    // moved in and back after it
                    val elem = this.slice_elem(p.ty);
                    var helper = S("texts");
                    var k = index_of(&this.texts, elem);
                    val h = this.handle_of(elem);
                    if (h) {
                        helper = S("handles");
                        k = index_of(&this.handles, h);
                    }
                    pre.append(fmt4("        val {}_v = {}_in_{}({});\n", copy pn, copy helper, copy k, copy pn).as_str());
                    pre.append(fmt4("        defer {}_done_{}({}_v, {});\n", copy helper, copy k, copy pn, copy pn).as_str());
                    put(&args, fmt2("@slice({}_v, {}.len)", copy pn, copy pn));
                } else {
                    put(&args, this.unwrap_in(p.ty, copy pn, false));
                }
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
    if (fns.len() == 0 && b.handles.len == 0 && b.texts.len == 0 && b.closures.len == 0 && b.traits.len == 0 && b.lists.len == 0) {
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
    for (k) in 0..b.closures.len {
        if (b.relayed(@cast<u32>(k))) {
            b.relay_shim(@cast<u32>(k), &extra);
        }
    }
    var used = copy fns;
    used.append(extra.as_str());
    var out = S("// generated by voltc lib: the package's export fns in the forms other languages call\n// (see voltc bindings)\nnamespace __export {\n    @attributes([@intrinsic(\"volt_rt_malloc\")])\n    internal fn rt_malloc(size: usize) -> void*;\n    @attributes([@intrinsic(\"volt_rt_free\")])\n    internal fn rt_free(ptr: void*) -> void;\n");
    if (b.texts.len > 0) {
        out.append("\n    // owned text: the bytes, and what frees them (drop(owner); none: nothing to)\n    struct text {\n        ptr: u8*;\n        len: usize;\n        owner: void*;\n        drop: (extern \"C\" fn(void*) -> void)?;\n    }\n");
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
            out.append(fmt3("\n    fn untext_{}(t: text) -> {} {{\n        val v = {}::from(@cast<str>(@slice(t.ptr, t.len)));\n        val d = t.drop ?? return v;\n        d(t.owner);\n        return v;\n    }}\n", copy kk, copy ts, copy ts).as_str());
        }
    }
    for (k) in 0..b.texts.len {
        val ts = b.src(*b.texts.at(k));
        val kk = unum(@cast<u64>(k));
        if (contains(used.as_str(), fmt("opt_in_{}(", copy kk).as_str())) {
            out.append(fmt3("\n    fn opt_in_{}(x: str?) -> {}? {{\n        val s = x ?? return null;\n        return {}::from(s);\n    }}\n", copy kk, copy ts, copy ts).as_str());
        }
        if (contains(used.as_str(), fmt("give_opt_text_{}(", copy kk).as_str())) {
            out.append(fmt5("\n    // an optional text given to C: has, and the text when it has\n    struct opt_text_{} {{\n        value: text;\n        has: bool;\n    }}\n\n    extern \"C\" fn drop_none_{}(p: void*) -> void {{\n    }}\n\n    fn give_opt_text_{}(v: {}?) -> opt_text_{} {{\n", copy kk, copy kk, copy kk, copy ts, copy kk).as_str());
            out.append(fmt2("        val x = v ?? return {{ value: {{ ptr: null, len: 0, owner: null, drop: drop_none_{} }}, has: false }};\n        return {{ value: text_{}(move x), has: true }};\n    }}\n", copy kk, copy kk).as_str());
        }
        if (contains(used.as_str(), fmt("texts_in_{}(", copy kk).as_str())) {
            out.append(fmt4("\n    // text C lends, as Volt's for a call (texts_done_{} frees it)\n    fn texts_in_{}(xs: str[..]) -> {}* {{\n        fits(xs.len, @sizeof({}));\n", copy kk, copy kk, copy ts, copy ts).as_str());
            out.append(fmt("        val p = @cast<{}*>(rt_malloc(xs.len * @sizeof(", copy ts).as_str());
            out.append(fmt4("{}) + 1) ?? @panic(\"out of memory\"));\n        for (k) in 0..xs.len {{\n            @write(@cast<{}*>(@cast<usize>(p) + k * @sizeof({})), {}::from(xs[k]));\n        }}\n        return p;\n    }}\n", copy ts, copy ts, copy ts, copy ts).as_str());
            out.append(fmt4("\n    fn texts_done_{}(p: {}*, xs: str[..]) -> void {{\n        for (k) in 0..xs.len {{\n            val v = @read(@cast<{}*>(@cast<usize>(p) + k * @sizeof({})));\n        }}\n        rt_free(@cast<void*>(p));\n    }}\n", copy kk, copy ts, copy ts, copy ts).as_str());
        }
    }
    for (k) in 0..b.handles.len {
        val xs = S(this.si(*b.handles.at(k)).name);
        val kk = unum(@cast<u64>(k));
        if (contains(used.as_str(), fmt("opt_own_{}(", copy kk).as_str())) {
            out.append(fmt3("\n    fn opt_own_{}(v: {}?) -> {}* {{\n        val x = v ?? return null;\n", copy kk, copy xs, copy xs).as_str());
            out.append(fmt("        return own_{}(move x);\n    }\n", copy kk).as_str());
        }
        if (contains(used.as_str(), fmt("opt_take_{}(", copy kk).as_str())) {
            out.append(fmt4("\n    fn opt_take_{}(p: {}*) -> {}? {{\n        if (p == null) {{\n            return null;\n        }}\n        return take_{}(p);\n    }}\n", copy kk, copy xs, copy xs, copy kk).as_str());
        }
        if (contains(used.as_str(), fmt("handles_in_{}(", copy kk).as_str())) {
            // handles C lends as a slice: their values moved into one array for the call, and back
            // (each once: two copies of one value would each own what it holds)
            out.append(fmt4("\n    fn handles_in_{}(xs: ({}*)[..]) -> {}* {{\n        fits(xs.len, @sizeof({}));\n        distinct(@cast<(void*)[..]>(xs));\n", copy kk, copy xs, copy xs, copy xs).as_str());
            out.append(fmt("        val p = @cast<{}*>(rt_malloc(xs.len * @sizeof(", copy xs).as_str());
            out.append(fmt3("{}) + 1) ?? @panic(\"out of memory\"));\n        for (k) in 0..xs.len {{\n            @write(@cast<{}*>(@cast<usize>(p) + k * @sizeof({})), @read(xs[k]));\n        }}\n        return p;\n    }}\n", copy xs, copy xs, copy xs).as_str());
            out.append(fmt4("\n    fn handles_done_{}(p: {}*, xs: ({}*)[..]) -> void {{\n        for (k) in 0..xs.len {{\n            @write(xs[k], @read(@cast<{}*>(@cast<usize>(p) + k * @sizeof(", copy kk, copy xs, copy xs, copy xs).as_str());
            out.append(fmt("{}))));\n        }\n        rt_free(@cast<void*>(p));\n    }\n", copy xs).as_str());
        }
    }
    for (k) in 0..b.lists.len {
        b.list_shim(@cast<u32>(k), used.as_str(), &out);
    }
    if (contains(out.as_str(), "fits(")) {
        out.append("\n    // a slice C gives: n elements of size bytes have to fit in memory (one more byte is added)\n    fn fits(n: usize, size: usize) -> void {\n        if (size != 0 && n >= (@cast<usize>(0) -% 1) / size) {\n            @panic(\"a slice from C is too long\");\n        }\n    }\n");
    }
    if (contains(extra.as_str(), "zeroed(")) {
        out.append("\n    // n zero bytes, where a relay's result goes (zeros if the other language never writes it)\n    fn zeroed(n: usize) -> void* {\n        val p = @cast<u8*>(rt_malloc(n + 1) ?? @panic(\"out of memory\"));\n        for (i) in 0..n {\n            p[i] = 0;\n        }\n        return @cast<void*>(p);\n    }\n");
    }
    if (contains(out.as_str(), "distinct(")) {
        // ponytail: compares each pair (O(n^2)); sort a copy if huge slices of handles show up
        out.append("\n    // handles C gives in one slice: each once (two copies of a value would both own what it holds)\n    fn distinct(xs: (void*)[..]) -> void {\n        for (i) in 0..xs.len {\n            for (j) in 0..i {\n                if (xs[i] == xs[j]) {\n                    @panic(\"a handle is in the slice twice\");\n                }\n            }\n        }\n    }\n");
    }
    if (b.lists.len > 0) {
        out.append(fmt("\n    // frees a list an export fn gave out, for languages that can't call a C function pointer\n    export fn {}_list_free(owner: void*, drop: extern \"C\" fn(void*) -> void) -> void {{\n        drop(owner);\n    }}\n", S(pkg)).as_str());
    }
    if (b.texts.len > 0) {
        // owned text freed by a real symbol, for languages that can't call a C function pointer
        out.append(fmt("\n    // frees owned text an export fn gave out\n    export fn {}_text_free(t: text) -> void {{\n        val d = t.drop ?? return;\n        d(t.owner);\n    }}\n", S(pkg)).as_str());
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

// list type K (std::vec<T>): given to C as its elements' views, how many, and what frees them
// (give_list_K); taken from C as a slice of views, copied (unlist_K: text copied, handles given)
attach fn list_shim(this: bind&, k: u32, used: str, out: std::string&) -> void {
    val t = *this.lists.at(k);
    val e = this.list_elem(t);
    val vs = this.src(t);
    val es = this.src(e);
    val kk = unum(@cast<u64>(k));
    val view = this.view_src(e);
    val items = S("items");
    if (contains(used, fmt("give_list_{}(", copy kk).as_str())) {
        out.append(fmt3("\n    // {} given to C: its elements (lent), how many, and what frees them\n    struct list_{} {{\n        ptr: {}*;\n        len: usize;\n        owner: void*;\n        drop: extern \"C\" fn(void*) -> void;\n    }}\n", copy vs, copy kk, copy view).as_str());
        if (this.view_of(e) == e) {
            // the vec's own elements
            out.append(fmt3("\n    extern \"C\" fn drop_list_{}(p: void*) -> void {{\n        val v = @read(@cast<{}*>(p));\n        rt_free(p);\n    }}\n\n    fn give_list_{}(", copy kk, copy vs, copy kk).as_str());
            out.append(fmt4("v: {}) -> list_{} {{\n        val p = @cast<{}*>(rt_malloc(@sizeof({})) ?? @panic(\"out of memory\"));\n", copy vs, copy kk, copy vs, copy vs).as_str());
            out.append(fmt2("        @write(p, move v);\n        val xs = p->{}();\n        return {{ ptr: xs.ptr, len: xs.len, owner: @cast<void*>(p), drop: drop_list_{} }};\n    }}\n", copy items, copy kk).as_str());
        } else if (this.view_of(e) == STR) {
            // the vec, and its text's views next to it
            var method = S("as_str");
            match (*this.c.t.get(e)) {
                .STRUCT(st) => { method = S(this.text_method(st) ?? "as_str"); },
                default => {},
            }
            out.append(fmt3("\n    struct held_{} {{\n        v: {};\n        views: str*;\n    }}\n\n    extern \"C\" fn drop_list_{}(p: void*) -> void {{\n", copy kk, copy vs, copy kk).as_str());
            out.append(fmt2("        val h = @read(@cast<held_{}*>(p));\n        rt_free(@cast<void*>(h.views));\n        rt_free(p);\n    }}\n\n    fn give_list_{}(", copy kk, copy kk).as_str());
            out.append(fmt4("v: {}) -> list_{} {{\n        val p = @cast<held_{}*>(rt_malloc(@sizeof(held_{})) ?? @panic(\"out of memory\"));\n", copy vs, copy kk, copy kk, copy kk).as_str());
            out.append(fmt2("        val n = v.{}().len;\n        val views = @cast<str*>(rt_malloc(n * @sizeof(str) + 1) ?? @panic(\"out of memory\"));\n        @write(p, {{ v: move v, views: views }});\n        val xs = p->v.{}();\n", copy items, copy items).as_str());
            out.append(fmt2("        for (k) in 0..n {{\n            @write(@cast<str*>(@cast<usize>(views) + k * @sizeof(str)), xs[k].{}());\n        }}\n        return {{ ptr: views, len: n, owner: @cast<void*>(p), drop: drop_list_{} }};\n    }}\n", move method, copy kk).as_str());
        } else {
            // each handle given its own (the caller frees each); the list holds their pointers
            var hk = S("0");
            match (this.shape_of(e) ?? shape::VOID) {
                .HANDLE(h) => { hk = index_of(&this.handles, h); },
                default => {},
            }
            out.append(fmt3("\n    extern \"C\" fn drop_list_{}(p: void*) -> void {{\n        rt_free(p);\n    }}\n\n    fn give_list_{}(v: {}) -> list_", copy kk, copy kk, copy vs).as_str());
            out.append(fmt4("{} {{\n        var w = move v;\n        val n = w.{}().len;\n        val hs = @cast<{}*>(rt_malloc(n * @sizeof({}) + 1) ?? @panic(\"out of memory\"));\n", copy kk, copy items, copy view, copy view).as_str());
            out.append(fmt3("        var k = n;\n        while (k > 0) {{\n            k -= 1;\n            val x = w.pop() ?? @panic(\"a list's element is gone\");\n            @write(@cast<{}*>(@cast<usize>(hs) + k * @sizeof({})), own_{}(move x));\n        }}\n", copy view, copy view, copy hk).as_str());
            out.append(fmt("        return {{ ptr: hs, len: n, owner: @cast<void*>(hs), drop: drop_list_{} }};\n    }}\n", copy kk).as_str());
        }
    }
    if (contains(used, fmt("unlist_{}(", copy kk).as_str())) {
        var conv = S("x");
        var check: std::string = {};
        match (this.shape_of(e) ?? shape::VOID) {
            .TEXT(x) => { conv = fmt("{}::from(x)", copy es); },
            .HANDLE(h) => {
                conv = fmt("take_{}(x)", index_of(&this.handles, h));
                // each taken once
                check = S("        distinct(@cast<(void*)[..]>(xs));\n");
            },
            default => {},
        }
        out.append(fmt4("\n    // {} from C: its elements copied (handles given to Volt)\n    fn unlist_{}(xs: {}[..]) -> {} {{\n", copy vs, copy kk, copy view, copy vs).as_str());
        out.append(check.as_str());
        out.append(fmt2("        var v: {} = {{}};\n        for (x) in xs {{\n            v.push({}) catch @panic(\"out of memory\");\n        }}\n        return v;\n    }}\n", copy vs, move conv).as_str());
    }
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
    // the relays of the fns giving a struct (see by_out): their object is a relay_vt_K
    var fields: std::string = {};
    for (f&) in fns.items() {
        if (this.by_out(f.ret)) {
            fields.append(fmt2("        {}: {};\n", S(f.name), this.relay_src(&f.params, f.ret)).as_str());
        }
    }
    if (fields.len() > 0) {
        out.append(fmt3("\n    // a {}'s object from a language whose C functions can't give a struct: the fns giving one,\n    // writing it through a pointer\n    struct relay_vt_{} {{\n{}        self_: void*;\n    }}\n", copy ts, copy kk, move fields).as_str());
        for (f&) in fns.items() {
            if (this.by_out(f.ret)) {
                out.append(this.relay_fn(fmt2("{}_{}_relay", this.c_named(this.short(t).as_str(), false), S(f.name)), fmt("relay_vt_{}", copy kk), f.name, "self_", &f.params, f.ret).as_str());
            }
        }
    }
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

// does a C function give t's C form back as a struct (str, text, a struct, E!T, a slice)? Python's
// ctypes can't make a callback that does, so voltc lib adds a relay for each closure parameter and
// trait fn giving one: a C function giving it, which calls one writing it through a pointer
attach fn by_out(this: bind&, t: u32) -> bool {
    match (this.shape_of(t) ?? shape::VOID) {
        .STR => { return true; },
        .TEXT(x) => { return true; },
        .STRUCT(s) => { return true; },
        .RESULT(e, x) => { return true; },
        .SLICE(x) => { return true; },
        default => { return false; },
    }
}

// is closure type K an export fn's parameter whose result comes back by_out (it has a relay)?
attach fn relayed(this: bind&, k: u32) -> bool {
    var ps: std::vec<u32> = {};
    if (!this.by_out(this.fn_parts(*this.closures.at(k), &ps))) {
        return false;
    }
    for (i&) in this.exports().items() {
        for (p&) in this.c.fi(*i).params.items() {
            match (this.shape_of(p.ty) ?? shape::VOID) {
                .CLOSURE(c) => {
                    if (c == k) {
                        return true;
                    }
                },
                default => {},
            }
        }
    }
    return false;
}

// the C function type a relay calls: the data, where the result goes, then ps' C forms
attach fn relay_src(this: bind&, ps: std::vec<u32>&, r: u32) -> std::string {
    var s = fmt("extern \"C\" fn(void*, {}*", this.c_src(r, true));
    for (p&) in ps.items() {
        s.append(", ");
        s.append(this.c_src(*p, false).as_str());
    }
    s.append(") -> void");
    return s;
}

// relay C function name (see by_out), whose first parameter points at a holder: it calls the
// holder's fn field with its data field and where the result goes (zeroed first), and gives it
attach fn relay_fn(this: bind&, name: std::string, holder: std::string, field: str, data: str, ps: std::vec<u32>&, r: u32) -> std::string {
    var params = S("p: void*");
    var args = fmt("r->{}, out", S(data));
    for (k) in 0..ps.len {
        params.append(fmt2(", a{}: {}", unum(@cast<u64>(k)), this.c_src(*ps.at(k), false)).as_str());
        args.append(fmt(", a{}", unum(@cast<u64>(k))).as_str());
    }
    val rs = this.c_src(r, true);
    var s = fmt4("\n    export fn {}({}) -> {} {{\n        val r = @cast<{}*>(p);\n", move name, move params, copy rs, move holder);
    s.append(fmt4("        val out = @cast<{}*>(zeroed(@sizeof({})));\n        val f = r->{};\n        f({});\n", copy rs, copy rs, S(field), move args).as_str());
    s.append("        val v = @read(out);\n        rt_free(@cast<void*>(out));\n        return v;\n    }\n");
    return s;
}

// closure type K's relay (see by_out): PKG_cbK_relay, whose data is a relay_K (the language's C
// function, which writes the result through a pointer, and its data)
attach fn relay_shim(this: bind&, k: u32, out: std::string&) -> void {
    val t = *this.closures.at(k);
    var ps: std::vec<u32> = {};
    val r = this.fn_parts(t, &ps);
    val kk = unum(@cast<u64>(k));
    out.append(fmt3("\n    // {} from a language whose C functions can't give a struct: its function and data\n    struct relay_{} {{\n        call: {};\n        data: void*;\n    }}\n", this.src(t), copy kk, this.relay_src(&ps, r)).as_str());
    out.append(this.relay_fn(fmt2("{}_cb{}_relay", S(this.pkg), copy kk), fmt("relay_{}", copy kk), "call", "data", &ps, r).as_str());
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
        // (a slice of optionals isn't a slice of their values)
        .OPT(x) => { return fmt("opt_{}", this.short(x)); },
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
        .OPT(x) => {
            // an optional handle is its pointer (null: none)
            match (this.shape_of(x) ?? shape::VOID) {
                .HANDLE(s) => { return this.handle_c(s, cpp); },
                default => {},
            }
            return this.made_name("opt", x, cpp);
        },
        .HANDLE(s) => { return this.handle_c(s, cpp); },
        .TEXT(x) => {
            if (cpp) {
                return S("text");
            }
            return S("volt_text");
        },
        .LIST(x) => { return this.made_name("list", this.list_elem(x), cpp); },
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

// type t's C form as a parameter: text comes in as a str (see in_ty)
attach fn c_in(this: bind&, t: u32, cpp: bool) -> std::string {
    return this.c_prim(this.in_ty(t), cpp);
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
            default => { args.append(this.c_decl(this.in_ty(p.ty), p.name, cpp).as_str()); },
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
    for (lt&) in this.layout.items() {
        match (*this.c.t.get(*lt)) {
            .OPT(x) => { put(&named, this.made_name("opt", x, cpp)); },
            default => {},
        }
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
    for (lt&) in this.lists.items() {
        val n = this.c_prim(*lt, cpp);
        val elem = spaced(this.c_prim(this.view_of(this.list_elem(*lt)), cpp));
        if (cpp) {
            out.append(fmt3("\n// {}, given out by a Volt function: its elements (lent), how many, and what frees them\nstruct {} {{\n    {}*ptr;\n    size_t len;\n    void *owner;\n    void (*drop)(void *owner);\n}};\n", this.c.ty_name(*lt), copy n, copy elem).as_str());
        } else {
            out.append(fmt3("\n// {}, given out by a Volt function: its elements (lent), how many, and what frees them\n// (drop(owner), or volt_list_free)\ntypedef struct {{\n    {}*ptr;\n    size_t len;\n    void *owner;\n    void (*drop)(void *owner);\n}} {};\n", this.c.ty_name(*lt), copy elem, copy n).as_str());
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
                out.append(fmt2("\n// a Volt optional: has says whether value is there\nstruct {} {{\n    {} value;\n    bool has;\n}};\n", copy n, this.c_prim(x, cpp)).as_str());
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
    if (this.lists.len > 0) {
        out.append("#ifndef VOLT_LIST_DEFINED\n#define VOLT_LIST_DEFINED\n// any list a Volt function gave out (each has these fields): free it with volt_list_free once\n// you're done with its elements\ntypedef struct {\n    const void *ptr;\n    size_t len;\n    void *owner;\n    void (*drop)(void *owner);\n} volt_list;\n\n#define volt_list_free(l) do { if ((l).drop) { (l).drop((l).owner); } } while (0)\n#endif\n\n");
    }
    this.c_types(false, &out);
    out.append("\n");
    for (e&) in ents.items() {
        out.append(fmt3("{}{}({});\n", spaced(this.c_ret(e, false)), copy e.name, this.c_params(e, false)).as_str());
    }
    if (this.texts.len > 0) {
        out.append(fmt("// the same as volt_text_free, as a function of the library\nvoid {}_text_free(volt_text t);\n", S(this.pkg)).as_str());
    }
    if (this.lists.len > 0) {
        out.append(fmt("// frees any list (its owner and drop), as a function of the library\nvoid {}_list_free(void *owner, void (*drop)(void *owner));\n", S(this.pkg)).as_str());
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
    // what C takes converted: containers of elements, optional text and handles
    if (this.cpp_conv_param(t, name, ty, arg)) {
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

// a parameter C takes converted, as C++ passes it (true when t is one): a std::vector of the
// elements for a list or a slice of text or handles (held for the call: hold), std::optional for an
// optional text or handle
attach fn cpp_conv_param(this: bind&, t: u32, name: str, ty: std::string&, arg: std::string&) -> bool {
    var elem = VOID;
    var given = false;
    match (this.shape_of(t) ?? shape::VOID) {
        .LIST(x) => {
            elem = this.list_elem(t);
            given = true;
        },
        .SLICE(v) => { elem = this.slice_elem(t); },
        .OPT(x) => {
            if (this.in_ty(x) == STR) {
                ty.append(fmt("std::optional<str> {}", S(name)).as_str());
                arg.append(fmt3("{}{{{}.value_or(str()), {}.has_value()}}", this.made_name("opt", STR, true), S(name), S(name)).as_str());
                return true;
            }
            val h = this.handle_of(x) ?? return false;
            // given to Volt: the class gives it up
            ty.append(fmt2("std::optional<{}> {}", this.local(this.c.si(h).name), S(name)).as_str());
            arg.append(fmt2("({} ? {}->release() : nullptr)", S(name), S(name)).as_str());
            return true;
        },
        default => { return false; },
    }
    val sl = this.made_name("slice", this.view_of(elem), true);
    val h = this.handle_of(elem);
    if (h) {
        val cls = this.local(this.c.si(h).name);
        if (given) {
            // given to Volt: each class gives its handle up
            ty.append(fmt2("std::vector<{}> {}", copy cls, S(name)).as_str());
            arg.append(fmt4("hold<{}, raw::{} *>({}, []({} &x) {{ return x.release(); }})", copy sl, copy cls, S(name), copy cls).as_str());
        } else {
            ty.append(fmt2("std::vector<{}> &{}", copy cls, S(name)).as_str());
            arg.append(fmt4("hold<{}, raw::{} *>({}, []({} &x) {{ return x.get(); }})", copy sl, copy cls, S(name), copy cls).as_str());
        }
        return true;
    }
    if (this.view_of(elem) == STR) {
        ty.append(fmt("const std::vector<std::string> &{}", S(name)).as_str());
        arg.append(fmt2("hold<{}, str>({}, [](const std::string &x) {{ return str(x); }})", copy sl, S(name)).as_str());
        return true;
    }
    if (!given) {
        // a slice of what C holds as it is: from a vector or an array
        return false;
    }
    val et = this.c_prim(elem, true);
    ty.append(fmt2("const std::vector<{}> &{}", copy et, S(name)).as_str());
    arg.append(fmt4("hold<{}, {}>({}, [](const {} &x) {{ return x; }})", copy sl, copy et, S(name), copy et).as_str());
    return true;
}

// the C++ type a list's element comes back as: text as std::string, a handle as its class
attach fn cpp_elem(this: bind&, e: u32) -> std::string {
    match (this.shape_of(e) ?? shape::VOID) {
        .TEXT(x) => { return S("std::string"); },
        .HANDLE(h) => { return this.local(this.c.si(h).name); },
        default => { return this.c_prim(e, true); },
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
        .OPT(x) => { return fmt("std::optional<{}>", this.cpp_elem(x)); },
        .LIST(x) => { return fmt("std::vector<{}>", this.cpp_elem(this.list_elem(t))); },
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
        .OPT(x) => {
            match (this.shape_of(x) ?? shape::VOID) {
                .TEXT(y) => { return fmt2("{}.has ? std::optional<std::string>(take_text({}.value)) : std::nullopt", S(r), S(r)); },
                .HANDLE(h) => { return fmt4("{} ? std::optional<{}>({}({})) : std::nullopt", S(r), this.local(this.c.si(h).name), this.local(this.c.si(h).name), S(r)); },
                default => {},
            }
            return fmt3("{}.has ? std::optional<{}>({}.value) : std::nullopt", S(r), this.c_prim(x, true), S(r));
        },
        .LIST(x) => {
            // copied into a std::vector, and the list freed (a handle's class owns it)
            val e = this.list_elem(t);
            val ce = this.cpp_elem(e);
            match (this.shape_of(e) ?? shape::VOID) {
                .TEXT(y) => { return fmt("take_list<std::string>({}, [](str x) { return std::string(x.view()); })", S(r)); },
                .HANDLE(h) => { return fmt4("take_list<{}>({}, [](raw::{} *x) {{ return {}(x); }})", copy ce, S(r), copy ce, copy ce); },
                default => { return fmt3("take_list<{}>({}, [](const {} &x) {{ return x; }})", copy ce, S(r), copy ce); },
            }
        },
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
        out.append("// a Volt str: bytes and a length (no terminator)\nstruct str {\n    const uint8_t *ptr;\n    size_t len;\n    str() : ptr(nullptr), len(0) {}\n    str(const char *s) : ptr((const uint8_t *)s), len(std::strlen(s)) {}\n    str(std::string_view s) : ptr((const uint8_t *)s.data()), len(s.size()) {}\n    str(const std::string &s) : ptr((const uint8_t *)s.data()), len(s.size()) {}\n    std::string_view view() const { return {(const char *)ptr, len}; }\n};\n\n");
    }
    if (this.texts.len > 0) {
        out.append("// owned text a Volt function gave out (the wrappers copy it into a std::string and free it)\nstruct text {\n    const uint8_t *ptr;\n    size_t len;\n    void *owner;\n    void (*drop)(void *owner);\n};\n\ninline std::string take_text(text t) {\n    std::string s((const char *)t.ptr, t.len);\n    if (t.drop) {\n        t.drop(t.owner);\n    }\n    return s;\n}\n\n// text C++ gives Volt (a callback's result): Volt frees it when it's done\ninline text give_text(std::string s) {\n    auto *o = new std::string(std::move(s));\n    return text{(const uint8_t *)o->data(), o->size(), o, [](void *p) { delete static_cast<std::string *>(p); }};\n}\n\n");
    }
    if (this.lists.len > 0 || this.converts_slices()) {
        out.append("// a container's elements as C takes them, held for one call\ntemplate <class S, class T> struct held {\n    std::unique_ptr<T[]> p;\n    size_t n;\n    operator S() { return S(p.get(), n); }\n};\n\ntemplate <class S, class T, class V, class F> held<S, T> hold(V &&v, F f) {\n    held<S, T> h{std::unique_ptr<T[]>(new T[v.size() + 1]), v.size()};\n    for (size_t i = 0; i < h.n; i++) {\n        h.p[i] = f(v[i]);\n    }\n    return h;\n}\n\n");
    }
    if (this.lists.len > 0) {
        out.append("// a list Volt gave out, as a std::vector (the list is freed)\ntemplate <class T, class L, class F> std::vector<T> take_list(L l, F f) {\n    std::vector<T> v;\n    v.reserve(l.len);\n    for (size_t i = 0; i < l.len; i++) {\n        v.push_back(f(l.ptr[i]));\n    }\n    if (l.drop) {\n        l.drop(l.owner);\n    }\n    return v;\n}\n\n");
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
        .OPT(x) => {
            // an optional handle is its pointer (null: none)
            match (this.shape_of(x) ?? shape::VOID) {
                .HANDLE(s) => { return fmt("*mut raw::{}", this.local(this.c.si(s).name)); },
                default => {},
            }
            return fmt("VoltOpt<{}>", this.rust_ty(x));
        },
        .HANDLE(s) => { return fmt("*mut raw::{}", this.local(this.c.si(s).name)); },
        .TEXT(x) => { return S("VoltText"); },
        .CLOSURE(i) => { return this.rust_fn_ty(t, true); },
        .TRAIT(i) => { return fmt("{}_obj", this.short(this.trait_of(t))); },
        .LIST(x) => { return fmt("VoltList<{}>", this.rust_ty(this.view_of(this.list_elem(x)))); },
    }
}

// type t's C form as a parameter: text comes in as a str (see in_ty)
attach fn rust_in(this: bind&, t: u32) -> std::string {
    return this.rust_ty(this.in_ty(t));
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
            if (!this.rust_elems(this.slice_elem(t), false, n.as_str(), ty, arg, pre, gens)) {
                ty.append(fmt2("{}: &mut [{}]", copy n, this.rust_ty(x)).as_str());
                arg.append(fmt("VoltSlice::from({})", copy n).as_str());
            }
        },
        .LIST(x) => {
            // given to Volt, which copies the elements (and takes the handles)
            val elem = this.list_elem(t);
            if (!this.rust_elems(elem, true, n.as_str(), ty, arg, pre, gens)) {
                ty.append(fmt2("mut {}: Vec<{}>", copy n, this.rust_ty(elem)).as_str());
                arg.append(fmt("VoltSlice::from(&mut {}[..])", copy n).as_str());
            }
        },
        .OPT(x) => {
            if (this.in_ty(x) == STR) {
                // str? or an optional text: Volt copies the text
                ty.append(fmt("{}: Option<&str>", copy n).as_str());
                arg.append(fmt("VoltOpt::from({}.map(VoltStr::from))", copy n).as_str());
                return;
            }
            match (this.shape_of(x) ?? shape::VOID) {
                .HANDLE(h) => {
                    // given to Volt, which frees it
                    ty.append(fmt2("{}: Option<{}>", copy n, this.local(this.c.si(h).name)).as_str());
                    arg.append(fmt("{}.map_or(std::ptr::null_mut(), |x| x.into_raw())", copy n).as_str());
                },
                default => {
                    ty.append(fmt2("{}: Option<{}>", copy n, this.rust_ty(x)).as_str());
                    arg.append(fmt("VoltOpt::from({})", copy n).as_str());
                },
            }
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

// a slice or a list of text or handles, as Rust passes it (true when elem is one): text from any
// &[impl AsRef<str>], handles from &mut [T] (lent) or Vec<T> (given), gathered for the call
attach fn rust_elems(this: bind&, elem: u32, given: bool, n: str, ty: std::string&, arg: std::string&, pre: std::string&, gens: std::string&) -> bool {
    if (this.view_of(elem) == STR) {
        if (gens.len() > 0) {
            gens.append(", ");
        }
        gens.append(fmt("S_{}: AsRef<str>", S(n)).as_str());
        ty.append(fmt2("{}: &[S_{}]", S(n), S(n)).as_str());
        pre.append(fmt2("    let mut {}_v: Vec<VoltStr> = {}.iter().map(|x| VoltStr::from(x.as_ref())).collect();\n", S(n), S(n)).as_str());
        arg.append(fmt("VoltSlice::from(&mut {}_v[..])", S(n)).as_str());
        return true;
    }
    val hs = this.handle_of(elem) ?? return false;
    val cls = this.local(this.c.si(hs).name);
    if (given) {
        ty.append(fmt2("{}: Vec<{}>", S(n), copy cls).as_str());
        pre.append(fmt3("    let mut {}_v: Vec<*mut raw::{}> = {}.into_iter().map(|x| x.into_raw()).collect();\n", S(n), copy cls, S(n)).as_str());
    } else {
        ty.append(fmt2("{}: &mut [{}]", S(n), copy cls).as_str());
        pre.append(fmt3("    let mut {}_v: Vec<*mut raw::{}> = {}.iter().map(|x| x.as_raw()).collect();\n", S(n), copy cls, S(n)).as_str());
    }
    arg.append(fmt("VoltSlice::from(&mut {}_v[..])", S(n)).as_str());
    return true;
}

// the Rust type a list's element or an optional's value comes back as
attach fn rust_elem(this: bind&, e: u32) -> std::string {
    match (this.shape_of(e) ?? shape::VOID) {
        .TEXT(x) => { return S("String"); },
        .HANDLE(h) => { return this.local(this.c.si(h).name); },
        default => { return this.rust_ty(e); },
    }
}

// what a wrapper returns in Rust for a C result of type t
attach fn rust_ret(this: bind&, t: u32) -> std::string {
    match (this.shape_of(t) ?? shape::VOID) {
        .VOID => { return S("()"); },
        .STR => { return S("String"); },
        .TEXT(x) => { return S("String"); },
        .HANDLE(s) => { return this.local(this.c.si(s).name); },
        .OPT(x) => { return fmt("Option<{}>", this.rust_elem(x)); },
        .LIST(x) => { return fmt("Vec<{}>", this.rust_elem(this.list_elem(t))); },
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
        .OPT(x) => {
            match (this.shape_of(x) ?? shape::VOID) {
                .TEXT(y) => { return fmt("{}.get().map(|t| t.take())", S(r)); },
                .HANDLE(h) => { return fmt2("{{ let p = {}; if p.is_null() {{ None }} else {{ Some({}::from_raw(p)) }} }}", S(r), this.local(this.c.si(h).name)); },
                default => {},
            }
            return fmt("{}.get()", S(r));
        },
        .LIST(x) => {
            // copied into a Vec, and the list freed (each handle is the Vec's)
            match (this.shape_of(this.list_elem(t)) ?? shape::VOID) {
                .TEXT(y) => { return fmt("{}.take(|x| unsafe { x.to_string() })", S(r)); },
                .HANDLE(h) => { return fmt2("{}.take(|x| {}::from_raw(*x))", S(r), this.local(this.c.si(h).name)); },
                default => { return fmt("{}.take(|x| *x)", S(r)); },
            }
        },
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
    if (this.lists.len > 0) {
        out.append("\n/// a list Volt gave out: its elements, how many, and what frees them (take copies them out\n/// and frees it)\n#[repr(C)]\npub struct VoltList<T> {\n    pub ptr: *mut T,\n    pub len: usize,\n    pub owner: *mut std::os::raw::c_void,\n    pub drop: Option<unsafe extern \"C\" fn(*mut std::os::raw::c_void)>,\n}\n\nimpl<T> VoltList<T> {\n    pub fn take<U>(self, f: impl Fn(&T) -> U) -> Vec<U> {\n        let v = if self.len == 0 {\n            Vec::new()\n        } else {\n            unsafe { std::slice::from_raw_parts(self.ptr, self.len) }.iter().map(f).collect()\n        };\n        if let Some(d) = self.drop {\n            unsafe { d(self.owner) };\n        }\n        v\n    }\n}\n");
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
        .OPT(x) => {
            match (this.shape_of(x) ?? shape::VOID) {
                .HANDLE(s) => { return fmt("?*raw.{}", this.local(this.c.si(s).name)); },
                default => {},
            }
            return fmt("VoltOpt({})", this.zig_ty(x));
        },
        .HANDLE(s) => { return fmt("*raw.{}", this.local(this.c.si(s).name)); },
        .TEXT(x) => { return S("VoltText"); },
        .CLOSURE(i) => { return this.zig_fn_ty(t, true); },
        .TRAIT(i) => { return fmt("{}_obj", this.short(this.trait_of(t))); },
        .LIST(x) => { return fmt("VoltList({})", this.zig_ty(this.view_of(this.list_elem(x)))); },
    }
}

// type t's C form as a parameter: text comes in as a str (see in_ty; an optional handle is nullable)
attach fn zig_in(this: bind&, t: u32) -> std::string {
    match (this.shape_of(t) ?? shape::VOID) {
        .OPT(x) => {
            // an optional handle given: null is none
            match (this.shape_of(x) ?? shape::VOID) {
                .HANDLE(h) => { return fmt("?*raw.{}", this.local(this.c.si(h).name)); },
                default => {},
            }
        },
        default => {},
    }
    return this.zig_ty(this.in_ty(t));
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
            if (!this.zig_elems(this.slice_elem(t), name, ty, arg, pre)) {
                ty.append(fmt2("{}: []{}", S(name), this.zig_ty(x)).as_str());
                arg.append(fmt2("VoltSlice({}).from({})", this.zig_ty(x), S(name)).as_str());
            }
        },
        .LIST(x) => {
            // given to Volt, which copies the elements (and takes the handles: don't deinit them)
            val elem = this.list_elem(t);
            if (!this.zig_elems(elem, name, ty, arg, pre)) {
                val et = this.zig_ty(elem);
                ty.append(fmt2("{}: []const {}", S(name), copy et).as_str());
                arg.append(fmt2("VoltSlice({}){{ .ptr = @constCast({}.ptr), .len = ", copy et, S(name)).as_str());
                arg.append(fmt("{}.len }", S(name)).as_str());
            }
        },
        .OPT(x) => {
            if (this.in_ty(x) == STR) {
                // str? or an optional text: Volt copies the text
                ty.append(fmt("{}: ?[]const u8", S(name)).as_str());
                arg.append(fmt("VoltOpt(VoltStr).from(if ({}) |s| VoltStr.from(s) else null)", S(name)).as_str());
                return;
            }
            match (this.shape_of(x) ?? shape::VOID) {
                .HANDLE(h) => {
                    // given to Volt, which frees it (don't deinit it after)
                    ty.append(fmt2("{}: ?{}", S(name), this.local(this.c.si(h).name)).as_str());
                    arg.append(fmt("if ({}) |h| h.raw else null", S(name)).as_str());
                },
                default => {
                    ty.append(fmt2("{}: ?{}", S(name), this.zig_ty(x)).as_str());
                    arg.append(fmt2("VoltOpt({}).from({})", this.zig_ty(x), S(name)).as_str());
                },
            }
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

// a slice or a list of text or handles, as Zig passes it (true when elem is one): text from any
// []const []const u8 (each made a VoltStr for the call), handles from []const T (T is laid out as
// its pointer)
attach fn zig_elems(this: bind&, elem: u32, name: str, ty: std::string&, arg: std::string&, pre: std::string&) -> bool {
    if (this.view_of(elem) == STR) {
        ty.append(fmt("{}: []const []const u8", S(name)).as_str());
        pre.append(fmt3("    const {}_v = std.heap.c_allocator.alloc(VoltStr, {}.len) catch @panic(\"out of memory\");\n    defer std.heap.c_allocator.free({}_v);\n", S(name), S(name), S(name)).as_str());
        pre.append(fmt2("    for ({}, {}_v) |x, *s| s.* = VoltStr.from(x);\n", S(name), S(name)).as_str());
        arg.append(fmt("VoltSlice(VoltStr).from({}_v)", S(name)).as_str());
        return true;
    }
    val hs = this.handle_of(elem) ?? return false;
    val cls = this.local(this.c.si(hs).name);
    ty.append(fmt2("{}: []const {}", S(name), copy cls).as_str());
    arg.append(fmt3("VoltSlice(*raw.{}){{ .ptr = @ptrCast(@constCast({}.ptr)), .len = {}.len }}", copy cls, S(name), S(name)).as_str());
    return true;
}

attach fn zig_ret(this: bind&, t: u32) -> std::string {
    match (this.shape_of(t) ?? shape::VOID) {
        .STR => { return S("[]const u8"); },
        .HANDLE(s) => { return this.local(this.c.si(s).name); },
        .OPT(x) => {
            match (this.shape_of(x) ?? shape::VOID) {
                .HANDLE(h) => { return fmt("?{}", this.local(this.c.si(h).name)); },
                default => {},
            }
            return fmt("?{}", this.zig_ty(x));
        },
        .LIST(x) => {
            // a handle's type is laid out as its pointer: the list holds the handles
            match (this.shape_of(this.list_elem(t)) ?? shape::VOID) {
                .HANDLE(h) => { return fmt("VoltList({})", this.local(this.c.si(h).name)); },
                default => {},
            }
            return this.zig_ty(t);
        },
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
        .OPT(x) => {
            match (this.shape_of(x) ?? shape::VOID) {
                .HANDLE(h) => { return fmt2("if ({}) |p| {}{{ .raw = p }} else null", S(r), this.local(this.c.si(h).name)); },
                default => {},
            }
            return fmt("{}.get()", S(r));
        },
        .LIST(x) => {
            match (this.shape_of(this.list_elem(t)) ?? shape::VOID) {
                .HANDLE(h) => { return fmt5("{}{{ .ptr = @ptrCast({}.ptr), .len = {}.len, .owner = {}.owner, .drop = {}.drop }}", this.zig_ret(t), S(r), S(r), S(r), S(r)); },
                default => { return S(r); },
            }
        },
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
    if (this.lists.len > 0) {
        out.append("\n/// a list Volt gave out: items(), then deinit() to free it (a handle in it is yours to deinit)\npub fn VoltList(comptime T: type) type {\n    return extern struct {\n        ptr: ?[*]T,\n        len: usize,\n        owner: ?*anyopaque,\n        drop: ?*const fn (?*anyopaque) callconv(.c) void,\n        pub fn items(self: @This()) []T {\n            return if (self.ptr) |p| p[0..self.len] else &[_]T{};\n        }\n        pub fn deinit(self: @This()) void {\n            if (self.drop) |d| d(self.owner);\n        }\n    };\n}\n");
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
        out.append(fmt4("\n/// export struct {}: owns a handle; deinit() frees it (one Volt lends, or one given to Volt,\n/// isn't yours to deinit)\npub const {} = extern struct {{\n    raw: *raw.{},\n\n    pub fn deinit(self: {}) void {{\n", S(this.c.si(*s).name), copy cls, copy cls, copy cls).as_str());
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

// t's C form as a ctypes type (a parameter's: see in_ty)
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
        .OPT(x) => {
            // an optional handle is its pointer (None: none)
            match (this.shape_of(x) ?? shape::VOID) {
                .HANDLE(s) => { return S("ctypes.c_void_p"); },
                default => {},
            }
            return this.made_name("opt", x, true);
        },
        .HANDLE(s) => { return S("ctypes.c_void_p"); },
        .TEXT(x) => { return S("VoltText"); },
        .CLOSURE(i) => { return this.py_fn_ty(t, true); },
        .TRAIT(i) => { return fmt("{}_obj", this.short(this.trait_of(t))); },
        .LIST(x) => { return this.made_name("list", this.list_elem(x), true); },
    }
}

// t's C form as a result: a closure comes out as closureK
attach fn py_out_ty(this: bind&, t: u32) -> std::string {
    match (this.shape_of(t) ?? shape::VOID) {
        .CLOSURE(i) => { return fmt("closure{}", unum(@cast<u64>(i))); },
        default => { return this.py_ty(t); },
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
    return this.py_cfn(&ps, r, user, false);
}

// a C function type in ctypes (data: a closure's or a trait fn's, taking its data first; relay: one
// a relay calls, writing the result through a pointer, see by_out)
attach fn py_cfn(this: bind&, ps: std::vec<u32>&, r: u32, data: bool, relay: bool) -> std::string {
    var s = S("ctypes.CFUNCTYPE(");
    if (relay) {
        s.append(fmt("None, ctypes.c_void_p, ctypes.POINTER({})", this.py_ty(r)).as_str());
    } else {
        s.append(this.py_ty(r).as_str());
        if (data) {
            s.append(", ctypes.c_void_p");
        }
    }
    for (p&) in ps.items() {
        s.append(", ");
        s.append(this.py_ty(this.in_ty(*p)).as_str());
    }
    s.push(')');
    return s;
}

// ", a0, a1": n parameters after self
fn py_params(n: usize) -> std::string {
    var out: std::string = {};
    for (k) in 0..n {
        out.append(fmt(", a{}", unum(@cast<u64>(k))).as_str());
    }
    return out;
}

// a wrapper's argument: what it passes to the C function for Python value name (pre: statements
// before the call, whose locals keep what Volt is lent alive until it returns; what Volt takes goes
// in _gift, given up once every argument is ready, see py_invoke)
attach fn py_arg(this: bind&, t: u32, name: str, conv: std::string&, pre: std::string&) -> void {
    match (this.shape_of(t) ?? shape::VOID) {
        .CLOSURE(i) => {
            // a C function calling the Python one
            var ps: std::vec<u32> = {};
            val r = this.fn_parts(t, &ps);
            pre.append(this.py_callback(fmt("_{}_c", S(name)).as_str(), name, &ps, r).as_str());
            if (this.by_out(r)) {
                // through the library's relay, which takes the result through a pointer
                pre.append(fmt3("    _{}_k = {}(_{}_c)\n", S(name), this.py_cfn(&ps, r, true, true), S(name)).as_str());
                pre.append(fmt2("    _{}_r = _Relay(_fn(_{}_k))\n", S(name), S(name)).as_str());
                conv.append(fmt4("ctypes.cast(_lib.{}_cb{}_relay, {}), ctypes.byref(_{}_r)", S(this.pkg), unum(@cast<u64>(i)), this.py_fn_ty(t, true), S(name)).as_str());
            } else {
                pre.append(fmt3("    _{}_k = {}(_{}_c)\n", S(name), this.py_fn_ty(t, true), S(name)).as_str());
                conv.append(fmt("_{}_k, None", S(name)).as_str());
            }
        },
        .TRAIT(i) => {
            // any object with the trait's fns: lent for the call, or given (kept until Volt drops it)
            var gift = S("_gift");
            if (this.is_ref(t)) {
                gift = S("None");
            }
            pre.append(fmt5("    _{}_o, _{}_k = _as_{}({}, {})\n", S(name), S(name), this.short(this.trait_of(t)), S(name), move gift).as_str());
            conv.append(fmt("_{}_o", S(name)).as_str());
        },
        default => { conv.append(this.py_in(t, name).as_str()); },
    }
}

// the C value of Python value x (of type t) Python passes Volt: text as a str (Volt copies it), a
// handle lent (checked open) or given (into _gift), a sequence as a slice
attach fn py_in(this: bind&, t: u32, x: str) -> std::string {
    // a handle lent: as T& (it has to be open), or as a nullable T* (None too)
    match (*this.c.t.get(t)) {
        .REF(y) => {
            if (this.lent_handle(t) != null) {
                return fmt("{}._lend()", S(x));
            }
        },
        .OPT(y) => {
            if (this.lent_handle(y) != null) {
                return fmt2("(None if {} is None else {}._lend())", S(x), S(x));
            }
        },
        default => {
            if (this.lent_handle(t) != null) {
                return fmt2("(None if {} is None else {}._lend())", S(x), S(x));
            }
        },
    }
    match (this.shape_of(t) ?? shape::VOID) {
        .STR => { return fmt("_str({})", S(x)); },
        .TEXT(y) => { return fmt("_str({})", S(x)); },
        .CSTR => { return fmt3("({}.encode() if isinstance({}, str) else {})", S(x), S(x), S(x)); },
        .PTR(y) => {
            // a structure by reference (or a pointer as it is)
            return fmt3("(ctypes.byref({}) if isinstance({}, ctypes.Structure) else {})", S(x), S(x), S(x));
        },
        .HANDLE(s) => { return fmt("_giving(_gift, {})", S(x)); },
        .SLICE(v) => { return fmt3("_slice({}, {}, {})", this.made_name("slice", v, true), this.py_ty(v), this.py_elems(this.slice_elem(t), false, x)); },
        .LIST(y) => {
            // a slice of the elements' views, which Volt copies (and the handles, Volt takes)
            val e = this.list_elem(t);
            val v = this.view_of(e);
            return fmt3("_slice({}, {}, {})", this.made_name("slice", v, true), this.py_ty(v), this.py_elems(e, true, x));
        },
        .OPT(v) => {
            if (this.in_ty(v) == STR) {
                return fmt3("_opt({}, None if {} is None else _str({}))", this.made_name("opt", STR, true), S(x), S(x));
            }
            match (this.shape_of(v) ?? shape::VOID) {
                .HANDLE(h) => { return fmt2("(None if {} is None else _giving(_gift, {}))", S(x), S(x)); },
                default => {},
            }
            return fmt2("_opt({}, {})", this.made_name("opt", v, true), S(x));
        },
        default => { return S(x); },
    }
}

// Python sequence x's elements as a slice of e's views, each converted as an argument would be (a
// handle by value is lent, but given from a list: given, Volt takes it)
attach fn py_elems(this: bind&, e: u32, given: bool, x: str) -> std::string {
    var c = this.py_in(e, "_x");
    match (this.shape_of(e) ?? shape::VOID) {
        .HANDLE(h) => {
            if (!given) {
                c = S("_x._lend()");
            }
        },
        default => {},
    }
    if (c.as_str() == "_x") {
        return S(x);
    }
    return fmt2("[{} for _x in {}]", move c, S(x));
}

// the Python value of C argument a (of type t) Volt passes a callback
attach fn py_from_c(this: bind&, t: u32, a: str) -> std::string {
    val h = this.lent_handle(t);
    if (h) {
        // a handle Volt lends: an object that never frees it
        return fmt2("{}._lent({})", this.local(this.c.si(h).name), S(a));
    }
    match (this.shape_of(t) ?? shape::VOID) {
        .STR => { return fmt("str({})", S(a)); },
        .TEXT(x) => { return fmt("str({})", S(a)); },
        .HANDLE(s) => { return fmt2("{}._wrap({})", this.local(this.c.si(s).name), S(a)); },
        default => { return S(a); },
    }
}

// the C form of Python value v (of type t) a callback gives Volt back, checked here (a number of
// the wrong type raises now, not after the callback)
attach fn py_give(this: bind&, t: u32, v: str) -> std::string {
    if (this.lent_handle(t) != null) {
        return fmt("{}._lend()", S(v));
    }
    match (this.shape_of(t) ?? shape::VOID) {
        .STR => { return fmt("_static({})", S(v)); },
        .TEXT(x) => { return fmt("_give_text({})", S(v)); },
        .HANDLE(s) => { return fmt("{}._give()", S(v)); },
        .INT(k) => { return fmt2("{}({}).value", this.py_ty(t), S(v)); },
        .FLOAT(b) => { return fmt2("{}({}).value", this.py_ty(t), S(v)); },
        .ENUM(e) => { return fmt2("{}({}).value", this.py_ty(t), S(v)); },
        .CODE => { return fmt2("{}({}).value", this.py_ty(t), S(v)); },
        default => { return S(v); },
    }
}

// what Volt gets from a callback that raised instead of giving t (the exception is raised again
// once Volt returns, see _reraise): nothing when there's nothing Volt could go on with (an
// object, a reference, a function), and the program ends (see _fatal)
attach fn py_stand_in(this: bind&, t: u32) -> std::string {
    match (*this.c.t.get(t)) {
        .REF(x) => { return {}; },
        default => {},
    }
    match (this.shape_of(t) ?? shape::VOID) {
        .STR => { return S("_static(\"\")"); },
        .TEXT(x) => { return S("_give_text(\"\")"); },
        .HANDLE(s) => { return {}; },
        .FN(i) => { return {}; },
        .PTR(x) => { return S("None"); },
        .STRUCT(s) => { return fmt("{}()", this.py_ty(t)); },
        .RESULT(e, x) => {
            // an error of E's own (its first), so Volt sees it fail
            var code = S("1");
            match (*this.c.t.get(e)) {
                .ENUM(id) => {
                    if (this.c.ei(id).values.len > 0) {
                        code = num(*this.c.ei(id).values.at(0));
                    }
                },
                default => {},
            }
            return fmt2("{}({})", this.py_ty(t), move code);
        },
        default => { return S("0"); },
    }
}

// def name: the C function Volt calls for a closure or a trait fn (taking its data first, unused:
// each is made for one target), calling Python's target; a result ctypes can't return (by_out) it
// writes through _out. An Error raised is E!T's code; anything else raised gives Volt a stand-in,
// and the call that led here raises it once Volt returns
attach fn py_callback(this: bind&, name: str, target: str, ps: std::vec<u32>&, r: u32) -> std::string {
    var params = S("_p");
    if (this.by_out(r)) {
        params.append(", _out");
    }
    params.append(py_params(ps.len).as_str());
    var args: std::string = {};
    for (k) in 0..ps.len {
        if (k > 0) {
            args.append(", ");
        }
        args.append(this.py_from_c(*ps.at(k), fmt("a{}", unum(@cast<u64>(k))).as_str()).as_str());
    }
    val call = fmt2("{}({})", S(target), move args);
    var out = fmt2("    def {}({}):\n        try:\n", S(name), move params);
    if (r == VOID) {
        out.append(fmt("            {}\n        except BaseException as e:\n            _stash(e)\n", move call).as_str());
        return out;
    }
    match (this.shape_of(r) ?? shape::VOID) {
        .RESULT(e, x) => {
            val rn = this.py_ty(r);
            if (x == VOID) {
                out.append(fmt2("            {}\n            _r = {}(0)\n", move call, copy rn).as_str());
            } else {
                out.append(fmt2("            _r = {}(0, {})\n", copy rn, this.py_give(x, call.as_str())).as_str());
            }
            out.append(fmt("        except Error as e:\n            _r = {}(e.code)\n", copy rn).as_str());
        },
        default => { out.append(fmt("            _r = {}\n", this.py_give(r, call.as_str())).as_str()); },
    }
    out.append("        except BaseException as e:\n");
    val stand_in = this.py_stand_in(r);
    if (stand_in.len() > 0) {
        out.append(fmt("            _stash(e)\n            _r = {}\n", copy stand_in).as_str());
    } else {
        out.append("            _fatal(e)\n");
    }
    if (this.by_out(r)) {
        out.append("        _out[0] = _r\n");
    } else {
        out.append("        return _r\n");
    }
    return out;
}

// the Python value of C result r (of type t)
attach fn py_value(this: bind&, t: u32, r: str) -> std::string {
    match (this.shape_of(t) ?? shape::VOID) {
        .STR => { return fmt("str({})", S(r)); },
        .CSTR => { return fmt2("({}.decode() if {} is not None else None)", S(r), S(r)); },
        .TEXT(x) => { return fmt("_take({})", S(r)); },
        .HANDLE(s) => { return fmt2("{}._wrap({})", this.local(this.c.si(s).name), S(r)); },
        .OPT(x) => {
            match (this.shape_of(x) ?? shape::VOID) {
                .TEXT(y) => { return fmt2("(_take({}.value) if {}.has else None)", S(r), S(r)); },
                .HANDLE(h) => { return fmt3("({}._wrap({}) if {} else None)", this.local(this.c.si(h).name), S(r), S(r)); },
                default => {},
            }
            return fmt2("({}.value if {}.has else None)", S(r), S(r));
        },
        .LIST(x) => {
            // copied into a Python list, and the list freed (each handle is Python's)
            var c = S("_x");
            match (this.shape_of(this.list_elem(t)) ?? shape::VOID) {
                .TEXT(y) => { c = S("str(_x)"); },
                .HANDLE(h) => { c = fmt("{}._wrap(_x)", this.local(this.c.si(h).name)); },
                .STRUCT(s) => { c = S("type(_x).from_buffer_copy(_x)"); },
                .OPT(y) => { c = S("(_x.value if _x.has else None)"); },
                default => {},
            }
            return fmt2("_list({}, lambda _x: {})", S(r), move c);
        },
        .TRAIT(i) => { return fmt2("_volt_{}({})", this.short(this.trait_of(t)), S(r)); },
        .CLOSURE(i) => { return fmt2("VoltFn({}, _call{})", S(r), unum(@cast<u64>(i))); },
        default => { return S(r); },
    }
}

// can Volt call Python (a closure parameter, or a trait Python implements)? Then every call checks
// whether a Python function it reached raised (see _reraise)
attach fn py_calls_back(this: bind&) -> bool {
    if (this.traits.len > 0) {
        return true;
    }
    for (i&) in this.exports().items() {
        for (p&) in this.c.fi(*i).params.items() {
            match (this.shape_of(p.ty) ?? shape::VOID) {
                .CLOSURE(c) => { return true; },
                default => {},
            }
        }
    }
    return false;
}

// "_gift = []" when the arguments give Volt anything (see py_invoke)
fn py_gift(pre: str, args: str) -> std::string {
    if (contains(pre, "_gift") || contains(args, "_gift")) {
        return S("    _gift = []\n");
    }
    return {};
}

// a call of C function f with args, its result in r: what it gives Volt (_gift) is given up only
// once every argument is ready, so one that can't convert leaves the rest Python's
attach fn py_invoke(this: bind&, f: str, args: std::string, gift: bool) -> std::string {
    if (gift) {
        return fmt2("    _a = ({},)\n    _given(_gift)\n    r = {}(*_a)\n", move args, S(f));
    }
    return fmt2("    r = {}({})\n", S(f), move args);
}

// statements calling f with args (giving t) and returning its Python value: an error is raised, and
// so is what a Python function Volt called raised (once its result is Python's, to be freed)
attach fn py_call(this: bind&, t: u32, f: str, args: std::string, gift: bool) -> std::string {
    var out = this.py_invoke(f, move args, gift);
    var back: std::string = {};
    if (this.py_calls_back()) {
        back = S("_reraise()\n");
    }
    match (this.shape_of(t) ?? shape::VOID) {
        .RESULT(e, x) => {
            out.append("    if r.error:\n");
            if (back.len() > 0) {
                out.append(fmt("        {}", copy back).as_str());
            }
            out.append("        _raise(r.error)\n");
            if (x != VOID) {
                if (back.len() > 0) {
                    out.append(fmt2("    v = {}\n    {}    return v\n", this.py_value(x, "r.value"), copy back).as_str());
                } else {
                    out.append(fmt("    return {}\n", this.py_value(x, "r.value")).as_str());
                }
            } else if (back.len() > 0) {
                out.append(fmt("    {}", copy back).as_str());
            }
        },
        .VOID => {
            if (back.len() > 0) {
                out.append(fmt("    {}", copy back).as_str());
            }
        },
        default => {
            if (back.len() > 0) {
                out.append(fmt2("    v = {}\n    {}    return v\n", this.py_value(t, "r"), copy back).as_str());
            } else {
                out.append(fmt("    return {}\n", this.py_value(t, "r")).as_str());
            }
        },
    }
    return out;
}

attach fn py_body(this: bind&, f: u32, conv: std::string, pre: std::string) -> std::string {
    val info = this.c.fi(f);
    var out = py_gift(pre.as_str(), conv.as_str());
    val gift = out.len() > 0;
    out.append(pre.as_str());
    out.append(this.py_call(info.ret, fmt("_lib.{}", S(info.c_name)).as_str(), move conv, gift).as_str());
    return out;
}

// what a Python function can't give Volt back, as a closure parameter's or a trait fn's result: a
// slice (nothing would keep its elements once the function returns)
attach fn py_check(this: bind&) -> compile_error!void {
    for (i&) in this.exports().items() {
        val f = this.c.fi(*i);
        for (p&) in f.params.items() {
            var rs: std::vec<u32> = {};
            match (this.shape_of(p.ty) ?? shape::VOID) {
                .CLOSURE(c) => {
                    var ps: std::vec<u32> = {};
                    put(&rs, this.fn_parts(p.ty, &ps));
                },
                .TRAIT(k) => {
                    for (tf&) in this.fns_of(this.trait_of(p.ty)).items() {
                        put(&rs, tf.ret);
                    }
                },
                default => {},
            }
            for (r&) in rs.items() {
                var v = *r;
                match (this.shape_of(v) ?? shape::VOID) {
                    .RESULT(e, x) => { v = x; },
                    default => {},
                }
                match (this.shape_of(v) ?? shape::VOID) {
                    .SLICE(x) => {
                        return with_help(fail(this.c.dl(f.decl).item.span, fmt3("export fn {}: its parameter {} gives back {}, which a Python function can't (nothing would keep the elements once it returns)", S(f.name), S(p.name), this.c.ty_name(*r))), S("give back text (std::string), a handle or plain values"));
                    },
                    default => {},
                }
            }
        }
    }
    return;
}

// trait K in Python: a class to subclass (its fns abstract); _volt_T, one Volt gave out (its fns
// call Volt's); and _as_T, any object with the fns as Volt's T (a table of C functions calling
// them, a result ctypes can't return going through the library's relay)
attach fn py_trait(this: bind&, k: u32, out: std::string&) -> void {
    val t = *this.traits.at(k);
    val tr = this.short(t);
    val fns = this.fns_of(t);
    out.append(fmt4("\n\nclass {}(abc.ABC):\n    \"\"\"trait {}: subclass it to hand Volt a {} (lent, or given: Volt drops it); one Volt\n    gives out is a {} too\"\"\"\n", copy tr, this.c.ty_name(t), copy tr, copy tr).as_str());
    for (f&) in fns.items() {
        out.append(fmt2("\n    @abc.abstractmethod\n    def {}(self{}):\n        ...\n", S(f.name), py_params(f.params.len)).as_str());
    }
    out.append(fmt3("\n\nclass _volt_{}({}):\n    \"\"\"a {} Volt gave out: its fns call Volt's; close() (or a with block) frees it\"\"\"\n\n    def __init__(self, o):\n        self._o = o\n", copy tr, copy tr, copy tr).as_str());
    for (f&) in fns.items() {
        var args = S("o.self");
        for (j) in 0..f.params.len {
            args.append(", ");
            args.append(this.py_in(*f.params.at(j), fmt("a{}", unum(@cast<u64>(j))).as_str()).as_str());
        }
        out.append(fmt2("\n    def {}(self{}):\n        o = self._o\n", S(f.name), py_params(f.params.len)).as_str());
        var b = py_gift("", args.as_str());
        val gift = b.len() > 0;
        b.append(this.py_call(f.ret, fmt("o.vt[0].{}", S(f.name)).as_str(), move args, gift).as_str());
        out.append(indent(b.as_str()).as_str());
    }
    out.append("\n    def close(self):\n        if self._o is not None:\n            if self._o.drop:\n                self._o.drop(self._o.self)\n            self._o = None\n\n    def __enter__(self):\n        return self\n\n    def __exit__(self, *exc):\n        self.close()\n\n    def __del__(self):\n        self.close()\n");
    // what Volt's relays take as the object: the fns writing their result through a pointer
    var relay: std::string = {};
    for (f&) in fns.items() {
        if (this.by_out(f.ret)) {
            relay.append(fmt("(\"{}\", ctypes.c_void_p), ", S(f.name)).as_str());
        }
    }
    if (relay.len() > 0) {
        out.append(fmt2("\n\nclass _{}_relay(ctypes.Structure):\n    _fields_ = [{}(\"self\", ctypes.c_void_p)]\n", copy tr, copy relay).as_str());
    }
    out.append(fmt3("\n\ndef _as_{}(o, gift):\n    \"\"\"o (an object with {}'s fns) as Volt's {}: lent for a call (gift None), or given (kept\n    from the call until Volt drops it)\"\"\"\n", copy tr, copy tr, copy tr).as_str());
    var fs: std::string = {};
    var vt: std::string = {};
    var held: std::string = {};
    for (j) in 0..fns.len {
        val f = fns.at(j);
        val jj = unum(@cast<u64>(j));
        out.append(this.py_callback(fmt("_{}", S(f.name)).as_str(), fmt("o.{}", S(f.name)).as_str(), &f.params, f.ret).as_str());
        if (j > 0) {
            fs.append(", ");
            vt.append(", ");
        }
        if (this.by_out(f.ret)) {
            fs.append(fmt3("_{}_out_{}(_{})", copy tr, S(f.name), S(f.name)).as_str());
            held.append(fmt("_fn(fs[{}]), ", copy jj).as_str());
            vt.append(fmt3("ctypes.cast(_lib.{}_{}_relay, _{}_vt_", this.c_named(tr.as_str(), false), S(f.name), copy tr).as_str());
            vt.append(fmt("{})", S(f.name)).as_str());
        } else {
            fs.append(fmt3("_{}_vt_{}(_{})", copy tr, S(f.name), S(f.name)).as_str());
            vt.append(fmt("fs[{}]", copy jj).as_str());
        }
    }
    out.append(fmt3("    fs = [{}]\n    vt = {}_vt({})\n", move fs, copy tr, move vt).as_str());
    if (relay.len() > 0) {
        out.append(fmt2("    s = _{}_relay({}None)\n", copy tr, move held).as_str());
    } else {
        out.append("    s = vt\n");
    }
    out.append(fmt("    return _object({}_obj, vt, s, (o, fs), gift)\n", copy tr).as_str());
}

attach fn py_text(this: bind&) -> std::string {
    val ents = this.entries();
    var out: std::string = {};
    out.append(fmt("# {}: generated by voltc bindings; the Volt package for Python (ctypes). It loads\n", S(this.pkg)).as_str());
    out.append(fmt2("# lib{}.so from $VOLT_{}_LIB, else from next to this file. Errors are raised as Error.\n", S(this.pkg), upper(this.pkg)).as_str());
    if (this.traits.len > 0) {
        out.append("import abc\n");
    }
    out.append("import ctypes\nimport os\n");
    if (this.py_calls_back()) {
        out.append("import sys\nimport threading\nimport traceback\n");
    }
    out.append("\n");
    out.append(fmt2("_lib = ctypes.CDLL(os.environ.get(\"VOLT_{}_LIB\") or os.path.join(os.path.dirname(os.path.abspath(__file__)), \"lib{}.so\"))\n", upper(this.pkg), S(this.pkg)).as_str());
    // the functions and classes first: the helpers they use come before them
    var body: std::string = {};
    for (t&) in this.traits.items() {
        val tr = this.short(*t);
        for (f&) in this.fns_of(*t).items() {
            body.append(fmt3("\n_{}_vt_{} = {}", copy tr, S(f.name), this.py_cfn(&f.params, f.ret, true, false)).as_str());
            if (this.by_out(f.ret)) {
                body.append(fmt3("\n_{}_out_{} = {}", copy tr, S(f.name), this.py_cfn(&f.params, f.ret, true, true)).as_str());
            }
        }
        var fields: std::string = {};
        for (f&) in this.fns_of(*t).items() {
            fields.append(fmt3("(\"{}\", _{}_vt_{}), ", S(f.name), copy tr, S(f.name)).as_str());
        }
        body.append(fmt2("\n{}_vt._fields_ = [{}]", copy tr, move fields).as_str());
    }
    for (i) in 0..this.closures.len {
        if (has_u32(&this.closures_out, @cast<u32>(i))) {
            body.append(fmt2("\nclosure{}._fields_ = [(\"call\", {}), (\"self\", ctypes.c_void_p), (\"drop\", ctypes.CFUNCTYPE(None, ctypes.c_void_p))]", unum(@cast<u64>(i)), this.py_fn_ty(*this.closures.at(i), true)).as_str());
        }
    }
    body.append("\n");
    // the C functions' types
    for (e&) in ents.items() {
        val s = e.free_of;
        if (s) {
            body.append(fmt2("\n_lib.{}.argtypes = [ctypes.c_void_p]\n_lib.{}.restype = None", copy e.name, copy e.name).as_str());
            continue;
        }
        val f = this.c.fi(e.f);
        var types: std::string = {};
        for (p&) in f.params.items() {
            if (types.len() > 0) {
                types.append(", ");
            }
            types.append(this.py_ty(this.in_ty(p.ty)).as_str());
            match (this.shape_of(p.ty) ?? shape::VOID) {
                .CLOSURE(i) => { types.append(", ctypes.c_void_p"); },
                default => {},
            }
        }
        body.append(fmt3("\n_lib.{}.argtypes = [{}]\n_lib.{}.restype = ", copy e.name, move types, copy e.name).as_str());
        body.append(this.py_out_ty(f.ret).as_str());
    }
    body.append("\n");
    // a closure Volt gives out: called through _callK
    for (i) in 0..this.closures.len {
        if (!has_u32(&this.closures_out, @cast<u32>(i))) {
            continue;
        }
        var ps: std::vec<u32> = {};
        val r = this.fn_parts(*this.closures.at(i), &ps);
        var args = S("c.self");
        for (k) in 0..ps.len {
            args.append(", ");
            args.append(this.py_in(*ps.at(k), fmt("a{}", unum(@cast<u64>(k))).as_str()).as_str());
        }
        body.append(fmt3("\n\n# calls {}, given out by Volt as c\ndef _call{}(c{}):\n", this.c.ty_name(*this.closures.at(i)), unum(@cast<u64>(i)), py_params(ps.len)).as_str());
        var b = py_gift("", args.as_str());
        val gift = b.len() > 0;
        b.append(this.py_call(r, "c.call", move args, gift).as_str());
        body.append(b.as_str());
    }
    for (k) in 0..this.traits.len {
        this.py_trait(@cast<u32>(k), &body);
    }
    // a class per export struct: it owns its handle (close(), a with block, or the garbage collector frees it)
    for (s&) in this.handles.items() {
        val cls = this.local(this.c.si(*s).name);
        body.append(fmt2("\n\nclass {}:\n    \"\"\"export struct {}: owns a handle; close() (or a with block) frees it\"\"\"\n\n    _h = None\n    _own = True\n", copy cls, S(this.c.si(*s).name)).as_str());
        body.append("\n    @classmethod\n    def _wrap(cls, h):\n        o = cls.__new__(cls)\n        o._h = h\n        return o\n\n    @classmethod\n    def _lent(cls, h):\n        \"\"\"a handle Volt lends (a callback's argument): never freed here\"\"\"\n        o = cls._wrap(h)\n        o._own = False\n        return o\n\n    def _lend(self):\n        \"\"\"the handle, lent to Volt for a call\"\"\"\n        if not self._h:\n            raise ValueError(type(self).__name__ + \" is closed or given away\")\n        return self._h\n\n    def _give(self):\n        \"\"\"the handle, given up to Volt (a callback's result), which frees it\"\"\"\n        h = _giving([], self)\n        self._h = None\n        return h\n");
        body.append(fmt("\n    def close(self):\n        if self._h and self._own:\n            _lib.{}(self._h)\n        self._h = None\n\n    def __enter__(self):\n        return self\n\n    def __exit__(self, *exc):\n        self.close()\n\n    def __del__(self):\n        self.close()\n", this.free_name(*s)).as_str());
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
                conv.append("self._lend()");
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
                body.append(fmt("\n    def __init__({}):\n", move ps).as_str());
                // __init__ keeps the handle the C function makes
                var b = py_gift(pre.as_str(), conv.as_str());
                val gift = b.len() > 0;
                b.append(pre.as_str());
                b.append(this.py_invoke(fmt("_lib.{}", S(info.c_name)).as_str(), move conv, gift).as_str());
                var back: std::string = {};
                if (this.py_calls_back()) {
                    back = S("_reraise()\n");
                }
                match (this.shape_of(info.ret) ?? shape::VOID) {
                    .RESULT(er, x) => {
                        b.append("    if r.error:\n");
                        if (back.len() > 0) {
                            b.append(fmt("        {}", copy back).as_str());
                        }
                        b.append("        _raise(r.error)\n    self._h = r.value\n");
                    },
                    default => { b.append("    self._h = r\n"); },
                }
                if (back.len() > 0) {
                    b.append(fmt("    {}", copy back).as_str());
                }
                body.append(indent(b.as_str()).as_str());
                continue;
            }
            if (!is_method) {
                body.append("\n    @staticmethod");
            }
            body.append(fmt2("\n    def {}({}):\n", S(m), move names).as_str());
            var b = this.py_body(e.f, move conv, move pre);
            body.append(indent(b.as_str()).as_str());
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
        body.append(fmt2("\n\ndef {}({}):\n", S(info.c_name), move names).as_str());
        body.append(this.py_body(e.f, move conv, move pre).as_str());
    }
    if (this.uses_str) {
        out.append("\n\nclass VoltStr(ctypes.Structure):\n    \"\"\"a Volt str: bytes and a length (no terminator)\"\"\"\n    _fields_ = [(\"ptr\", ctypes.c_void_p), (\"len\", ctypes.c_size_t)]\n\n    def __str__(self):\n        return ctypes.string_at(self.ptr, self.len).decode()\n\n\ndef _bytes(s):\n    if isinstance(s, str):\n        return s.encode()\n    if isinstance(s, (bytes, bytearray, memoryview)):\n        return bytes(s)\n    raise TypeError(\"expected str or bytes, not \" + type(s).__name__)\n\n\ndef _str(s):\n    b = _bytes(s)\n    v = VoltStr(ctypes.cast(ctypes.c_char_p(b), ctypes.c_void_p), len(b))\n    v._keep = b\n    return v\n");
    }
    if (contains(body.as_str(), "_static(")) {
        out.append("\n\n_static_strs = {}\n\n\ndef _static(s):\n    \"\"\"a str a callback gives Volt, which may keep it (it has no owner to free it, like Rust's\n    &'static str): kept as long as the program, once per value\"\"\"\n    return _static_strs.setdefault(s, _str(s))\n");
    }
    if (this.texts.len > 0) {
        out.append("\n\nclass VoltText(ctypes.Structure):\n    \"\"\"owned text a Volt function gave out (the wrappers copy it into a str and free it)\"\"\"\n    _fields_ = [(\"ptr\", ctypes.c_void_p), (\"len\", ctypes.c_size_t), (\"owner\", ctypes.c_void_p), (\"drop\", ctypes.CFUNCTYPE(None, ctypes.c_void_p))]\n\n\ndef _take(t):\n    try:\n        return ctypes.string_at(t.ptr, t.len).decode()\n    finally:\n        if t.drop:\n            t.drop(t.owner)\n");
    }
    if (contains(body.as_str(), "_give_text(") || contains(body.as_str(), "_object(") || contains(body.as_str(), "_giving(")) {
        out.append("\n\n# what Python gave Volt (text, objects), by address: kept until Volt drops it\n_kept = {}\n\n\n@ctypes.CFUNCTYPE(None, ctypes.c_void_p)\ndef _drop_kept(p):\n    _kept.pop(p, None)\n");
    }
    if (contains(body.as_str(), "_give_text(")) {
        out.append("\n\ndef _give_text(s):\n    \"\"\"text a callback gives Volt: kept until Volt drops it\"\"\"\n    b = _bytes(s)\n    buf = ctypes.create_string_buffer(b, len(b) + 1)\n    a = ctypes.addressof(buf)\n    _kept[a] = buf\n    return VoltText(a, len(b), a, _drop_kept)\n");
    }
    if (contains(body.as_str(), "_object(")) {
        out.append("\n\ndef _object(cls, vt, s, keep, gift):\n    \"\"\"a trait's object Python hands Volt: its table vt, and s, what Volt passes its fns; one given\n    (gift: what the call gives) is kept from the call until Volt drops it\"\"\"\n    o = cls(ctypes.pointer(vt), ctypes.addressof(s))\n    keep = (vt, s, keep)\n    if gift is not None:\n        o.drop = _drop_kept\n        gift.append((o.self, keep))\n    return o, keep\n");
    }
    if (contains(body.as_str(), "_giving(")) {
        out.append("\n\ndef _giving(gift, x):\n    \"\"\"x's handle, for Volt to take: checked now, given up with the rest of gift (_given)\"\"\"\n    if not x._h:\n        raise ValueError(type(x).__name__ + \" is closed or given away\")\n    if not x._own:\n        raise ValueError(type(x).__name__ + \" is lent: Volt can't take it\")\n    if any(y is x for y in gift):\n        raise ValueError(type(x).__name__ + \" is given twice\")\n    gift.append(x)\n    return x._h\n\n\ndef _given(gift):\n    \"\"\"what a call gives Volt, given up once every argument is ready: objects let go of their\n    handles, and Python objects are kept until Volt drops them\"\"\"\n    for x in gift:\n        if isinstance(x, tuple):\n            _kept[x[0]] = x[1]\n        else:\n            x._h = None\n");
    }
    if (contains(body.as_str(), "_stash(") || contains(body.as_str(), "_reraise(")) {
        out.append("\n\n# what a Python function Volt called raised, raised again once Volt returns (it got a stand-in)\n_raised = threading.local()\n\n\ndef _stash(e):\n    if getattr(_raised, \"e\", None) is None:\n        _raised.e = e\n\n\ndef _reraise():\n    e = getattr(_raised, \"e\", None)\n    if e is not None:\n        _raised.e = None\n        try:\n            raise e\n        finally:\n            e = None  # (else e, its traceback and this frame hold each other)\n\n\ndef _fatal(e):\n    \"\"\"a Python function that had to give Volt an object (a handle, a reference) raised: Volt has\n    nothing to go on with, so the program ends, as a Volt panic does\"\"\"\n    traceback.print_exception(e)\n    sys.stdout.flush()\n    sys.stderr.flush()\n    os._exit(101)\n");
    }
    if (contains(body.as_str(), "_fn(")) {
        out.append("\n\ndef _fn(f):\n    \"\"\"C function f's address (ctypes.cast would tie f, and what it calls, in a reference cycle)\"\"\"\n    return ctypes.c_void_p.from_address(ctypes.addressof(f)).value\n");
    }
    if (contains(body.as_str(), "_Relay(")) {
        out.append("\n\nclass _Relay(ctypes.Structure):\n    \"\"\"what the library's relay for a callback takes as its data: the Python function, writing the\n    result through a pointer (ctypes can't make a callback giving a struct)\"\"\"\n    _fields_ = [(\"call\", ctypes.c_void_p), (\"data\", ctypes.c_void_p)]\n");
    }
    if (this.closures_out.len > 0) {
        out.append("\n\nclass VoltFn:\n    \"\"\"a closure Volt gave out: call it like a function; close() (or a with block) frees it\"\"\"\n\n    def __init__(self, c, call):\n        self._c = c\n        self._call = call\n\n    def __call__(self, *a):\n        return self._call(self._c, *a)\n\n    def close(self):\n        if self._c is not None:\n            self._c.drop(self._c.self)\n            self._c = None\n\n    def __enter__(self):\n        return self\n\n    def __exit__(self, *exc):\n        self.close()\n\n    def __del__(self):\n        self.close()\n");
    }
    if (this.slices.len > 0) {
        out.append("\n\ndef _slice(cls, elem, xs):\n    arr = (elem * len(xs))(*xs)\n    v = cls(ctypes.cast(arr, ctypes.POINTER(elem)), len(xs))\n    v._keep = (arr, xs)\n    return v\n");
    }
    if (this.opts.len > 0) {
        out.append("\n\ndef _opt(cls, x):\n    o = cls()\n    if x is not None:\n        o.value = x\n        o.has = True\n        o._keep = x\n    return o\n");
    }
    if (this.lists.len > 0) {
        out.append("\n\ndef _list(l, conv):\n    \"\"\"a list Volt gave out: its elements converted, and the list freed\"\"\"\n    try:\n        return [conv(l.ptr[i]) for i in range(l.len)]\n    finally:\n        l.drop(l.owner)\n");
    }
    for (e&) in this.enums.items() {
        val info = this.c.ei(*e);
        out.append(fmt("\n\nclass {}:\n", this.local(info.name)).as_str());
        for (i) in 0..info.names.len {
            out.append(fmt2("    {} = {}\n", S(*info.names.at(i)), num(*info.values.at(i))).as_str());
        }
    }
    if (this.codes.len > 0) {
        out.append("\n\nclass Error(Exception):\n    \"\"\"an error a Volt function returned (or a callback raises): code, and name\"\"\"\n\n    def __init__(self, code):\n        self.code = code\n        self.name = _ERROR_NAMES.get(code, \"error\")\n        super().__init__(self.name)\n");
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
    var named: std::vec<std::string> = {};
    for (s&) in this.structs.items() {
        put(&named, this.local(this.c.si(*s).name));
    }
    for (x&) in this.slices.items() {
        put(&named, this.made_name("slice", *x, true));
    }
    for (x&) in this.opts.items() {
        put(&named, this.made_name("opt", *x, true));
    }
    for (lt&) in this.lists.items() {
        put(&named, this.py_ty(*lt));
    }
    for (t&) in this.traits.items() {
        put(&named, fmt("{}_vt", this.short(*t)));
        put(&named, fmt("{}_obj", this.short(*t)));
    }
    for (rt&) in this.results.items() {
        put(&named, this.result_name(*rt));
    }
    for (i) in 0..this.closures.len {
        if (has_u32(&this.closures_out, @cast<u32>(i))) {
            put(&named, fmt("closure{}", unum(@cast<u64>(i))));
        }
    }
    for (n&) in named.items() {
        out.append(fmt("\n\nclass {}(ctypes.Structure):\n    pass\n", copy *n).as_str());
    }
    out.append("\n");
    // a struct's fields after what it holds (a table of functions, and closures, come last: their
    // types may name any of them)
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
    for (lt&) in this.lists.items() {
        out.append(fmt2("\n{}._fields_ = [(\"ptr\", ctypes.POINTER({})), (\"len\", ctypes.c_size_t), (\"owner\", ctypes.c_void_p), (\"drop\", ctypes.CFUNCTYPE(None, ctypes.c_void_p))]", this.py_ty(*lt), this.py_ty(this.view_of(this.list_elem(*lt)))).as_str());
    }
    for (t&) in this.traits.items() {
        out.append(fmt2("\n{}_obj._fields_ = [(\"vt\", ctypes.POINTER({}_vt)), (\"self\", ctypes.c_void_p), (\"drop\", ctypes.CFUNCTYPE(None, ctypes.c_void_p))]", this.short(*t), this.short(*t)).as_str());
    }
    for (rt&) in this.results.items() {
        match (*this.c.t.get(*rt)) {
            .ERR_UNION(e, x) => {
                var fields = S("(\"error\", ctypes.c_uint32)");
                if (x != VOID) {
                    fields.append(fmt(", (\"value\", {})", this.py_out_ty(x)).as_str());
                }
                out.append(fmt2("\n{}._fields_ = [{}]", this.result_name(*rt), move fields).as_str());
            },
            default => {},
        }
    }
    out.append(body.as_str());
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
        .LIST(x) => {
            // owned elements: a list out (its c_name: ptr, len, owner, drop), a slice of them in
            o.set("kind", std::json::string("list"));
            o.set("of", this.json_ty(this.view_of(this.list_elem(x))));
            o.set("c_name", std::json::string(this.c_prim(x, false).as_str()));
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
            // a callback (incoming) takes what Volt gives; a closure Volt gave out, what Python does
            match (*this.c.t.get(t)) {
                .FN_VAL(ps&, r) => {
                    var s = S("Callable[[");
                    for (k) in 0..ps.len {
                        if (k > 0) {
                            s.append(", ");
                        }
                        s.append(this.pyi_ty(*ps.at(k), !incoming).as_str());
                    }
                    s.append("], ");
                    s.append(this.pyi_ty(r, incoming).as_str());
                    s.push(']');
                    return s;
                },
                default => { return S("Callable[..., Any]"); },
            }
        },
        .TRAIT(i) => { return this.short(this.trait_of(t)); },
        .LIST(x) => {
            if (incoming) {
                return fmt("Sequence[{}]", this.pyi_ty(this.list_elem(x), true));
            }
            return fmt("list[{}]", this.pyi_ty(this.list_elem(x), false));
        },
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
    out.append("# --lang python). Errors a Volt function returns are raised: a class per error set, all\n# deriving from Error.\n");
    if (this.traits.len > 0) {
        out.append("import abc\n");
    }
    out.append("from typing import Any, Callable, Sequence\n");
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
    for (t&) in this.traits.items() {
        out.append(fmt2("\n\nclass {}(abc.ABC):\n    \"\"\"trait {}: subclass it to hand Volt one\"\"\"\n\n", this.short(*t), this.c.ty_name(*t)).as_str());
        for (f&) in this.fns_of(*t).items() {
            var ps = S("self");
            for (k) in 0..f.params.len {
                ps.append(fmt2(", a{}: {}", unum(@cast<u64>(k)), this.pyi_ty(*f.params.at(k), false)).as_str());
            }
            out.append(fmt3("    @abc.abstractmethod\n    def {}({}) -> {}: ...\n", S(f.name), move ps, this.pyi_ty(f.ret, true)).as_str());
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
        .OPT(x) => {
            // an optional handle is its pointer (null: none)
            if (this.handle_of(x) != null) {
                return S("IntPtr");
            }
            return this.made_name("opt", x, true);
        },
        .FN(i) => { return S("IntPtr"); },
        .CLOSURE(i) => { return this.cs_fnptr(t); },
        .TRAIT(i) => { return fmt("{}_obj", this.short(this.trait_of(t))); },
        .LIST(x) => { return this.made_name("list", this.list_elem(x), true); },
    }
}

// type t's C form as a result: a closure comes out boxed (closureN_obj)
attach fn cs_out(this: bind&, t: u32) -> std::string {
    match (this.shape_of(t) ?? shape::VOID) {
        .CLOSURE(i) => { return fmt("closure{}_obj", unum(@cast<u64>(i))); },
        default => { return this.cs_raw(t); },
    }
}

// a closure parameter's C function: delegate* unmanaged<IntPtr, A..., R>
attach fn cs_fnptr(this: bind&, t: u32) -> std::string {
    var ps: std::vec<u32> = {};
    val r = this.fn_parts(t, &ps);
    return this.cs_fn_of(&ps, r);
}

// the C function a closure or a trait's fn is: the caller's data (or the object) first, text in as
// a str
attach fn cs_fn_of(this: bind&, ps: std::vec<u32>&, r: u32) -> std::string {
    var s = S("delegate* unmanaged<IntPtr");
    for (p&) in ps.items() {
        s.append(", ");
        s.append(this.cs_raw(this.in_ty(*p)).as_str());
    }
    s.append(", ");
    s.append(this.cs_raw(r).as_str());
    s.push('>');
    return s;
}

// what C# code gives or gets for t: E!T's T (its error is thrown), or t
attach fn cs_ok(this: bind&, t: u32) -> u32 {
    match (this.shape_of(t) ?? shape::VOID) {
        .RESULT(e, x) => { return x; },
        default => { return t; },
    }
}

// the C# type of a container's element or an optional's value (copied: bool is a bool): text as a
// string, a handle as its class
attach fn cs_elem(this: bind&, t: u32) -> std::string {
    if (this.in_ty(t) == STR) {
        return S("string");
    }
    val h = this.handle_of(t);
    if (h) {
        return this.local(this.c.si(h).name);
    }
    return this.cs_ty(t);
}

// a type as the C# API shows it (a parameter's, or a callback's)
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
        .SLICE(x) => {
            // text and handles from any IEnumerable, what C holds as it is from a Span
            val e = this.slice_elem(t);
            if (x == STR || this.handle_of(e) != null) {
                return fmt("IEnumerable<{}>", this.cs_elem(e));
            }
            return fmt("Span<{}>", this.cs_raw(x));
        },
        .LIST(x) => { return fmt("IEnumerable<{}>", this.cs_elem(this.list_elem(t))); },
        .OPT(x) => { return fmt("{}?", this.cs_elem(x)); },
        .RESULT(e, x) => { return this.cs_ty(x); },
        .TRAIT(i) => { return this.short(this.trait_of(t)); },
        .CLOSURE(i) => {
            var ps: std::vec<u32> = {};
            val r = this.fn_parts(t, &ps);
            var args: std::string = {};
            for (p&) in ps.items() {
                if (args.len() > 0) {
                    args.append(", ");
                }
                // an E!T argument as its struct (an error a callback gets isn't thrown)
                match (this.shape_of(*p) ?? shape::VOID) {
                    .RESULT(e, x) => { args.append(this.cs_raw(*p).as_str()); },
                    default => { args.append(this.cs_ty(*p).as_str()); },
                }
            }
            if (this.cs_ok(r) == VOID) {
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
        default => { return this.cs_raw(t); },
    }
}

// what a wrapper returns for a C result of type t: a closure as its closureN, a trait's value as
// volt_T, a list as a List
attach fn cs_ret(this: bind&, t: u32) -> std::string {
    match (this.shape_of(t) ?? shape::VOID) {
        .CLOSURE(i) => { return fmt("closure{}", unum(@cast<u64>(i))); },
        .TRAIT(i) => { return fmt("volt_{}", this.short(this.trait_of(t))); },
        .LIST(x) => { return fmt("List<{}>", this.cs_elem(this.list_elem(t))); },
        .RESULT(e, x) => { return this.cs_ret(x); },
        default => { return this.cs_ty(t); },
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
    if (this.in_ty(t) == STR) {
        // a str, or owned text (which Volt copies)
        a.decl = fmt("string {}", S(name));
        a.open = fmt3("byte[] {}_b = Encoding.UTF8.GetBytes({});\nfixed (byte* {}_p = ", S(name0), S(name), S(name0));
        a.open.append(fmt("{}_b) {{\n", S(name0)).as_str());
        a.pass = fmt2("new VoltStr {{ ptr = {}_p, len = (nuint){}_b.Length }}", S(name0), S(name0));
        a.close = S("}\n");
        return;
    }
    if (this.cs_elems(t, name0, name, a)) {
        return;
    }
    match (this.shape_of(t) ?? shape::VOID) {
        .BOOL => {
            a.decl = fmt("bool {}", S(name));
            a.pass = fmt("(byte)({} ? 1 : 0)", S(name));
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
            if (this.in_ty(x) == STR) {
                // text, which Volt copies (null: none)
                a.decl = fmt("string? {}", S(name));
                a.open = fmt3("byte[]? {}_b = {} == null ? null : Encoding.UTF8.GetBytes({});\n", S(name0), S(name), S(name));
                a.open.append(fmt2("fixed (byte* {}_p = {}_b) {{\n", S(name0), S(name0)).as_str());
                a.pass = fmt4("new {} {{ value = new VoltStr {{ ptr = {}_p, len = (nuint)({}_b?.Length ?? 0) }}, has = (byte)({} != null ? 1 : 0) }}", this.made_name("opt", STR, true), S(name0), S(name0), S(name));
                a.close = S("}\n");
                return;
            }
            val oh = this.handle_of(x);
            if (oh) {
                // given to Volt, which frees it (null: none)
                a.decl = fmt2("{}? {}", this.local(this.c.si(oh).name), S(name));
                a.pass = fmt2("({} == null ? IntPtr.Zero : {}.Release())", S(name), S(name));
                return;
            }
            a.decl = fmt2("{}? {}", this.cs_elem(x), S(name));
            a.pass = fmt3("new {} {{ value = {}, has = (byte)({}.HasValue ? 1 : 0) }}", this.made_name("opt", x, true), this.cs_give(x, fmt("{}.GetValueOrDefault()", S(name)).as_str()), S(name));
        },
        .HANDLE(s) => {
            // given to Volt, which frees it: the class lets its handle go
            a.decl = fmt2("{} {}", this.local(this.c.si(s).name), S(name));
            a.pass = fmt("{}.Release()", S(name));
        },
        .TRAIT(i) => {
            // a C# object, reached through a GCHandle to it: lent for the call, or given (Volt drops
            // it, which disposes it); what it throws comes out of this call
            val tn = this.short(this.trait_of(t));
            a.decl = fmt2("{} {}", copy tn, S(name));
            a.open = fmt3("var {}_s = new Callback({});\nGCHandle {}_g = GCHandle.Alloc(", S(name0), S(name), S(name0));
            a.open.append(fmt("{}_s);\n", S(name0)).as_str());
            if (this.is_ref(t)) {
                a.open.append("try {\n");
                a.pass = fmt3("new {}_obj {{ vt = {}_table.Vt, self = GCHandle.ToIntPtr({}_g), drop = null }}", copy tn, copy tn, S(name0));
                a.close = fmt2("}}\nfinally {{\n    {}_g.Free();\n}}\n{}_s.Rethrow();\n", S(name0), S(name0));
            } else {
                a.pass = fmt4("new {}_obj {{ vt = {}_table.Vt, self = GCHandle.ToIntPtr({}_g), drop = &{}_table.drop }}", copy tn, copy tn, S(name0), copy tn);
                a.close = fmt("{}_s.Rethrow();\n", S(name0));
            }
        },
        .CLOSURE(i) => {
            a.decl = fmt2("{} {}", this.cs_ty(t), S(name));
            // the C function finds the delegate through a GCHandle; an exception it throws comes back
            // out of this call
            a.open = fmt3("var {}_s = new Callback({});\nGCHandle {}_g = GCHandle.Alloc(", S(name0), S(name), S(name0));
            a.open.append(fmt("{}_s);\ntry {{\n", S(name0)).as_str());
            a.pass = fmt2("&Callbacks.cb{}, GCHandle.ToIntPtr({}_g)", unum(@cast<u64>(i)), S(name0));
            a.close = fmt2("}}\nfinally {{\n    {}_g.Free();\n}}\n{}_s.Rethrow();\n", S(name0), S(name0));
        },
        default => {
            a.decl = fmt2("{} {}", this.cs_ty(t), S(name));
            a.pass = S(name);
        },
    }
}

// a slice of text or handles, or a list, as C# passes it (true when t is one): from any IEnumerable,
// gathered for the call (text copied, handles lent; a list's handles are given up)
attach fn cs_elems(this: bind&, t: u32, name0: str, name: str, a: cs_arg&) -> bool {
    var elem = VOID;
    var given = false;
    match (this.shape_of(t) ?? shape::VOID) {
        .LIST(x) => {
            elem = this.list_elem(t);
            given = true;
        },
        .SLICE(x) => { elem = this.slice_elem(t); },
        default => { return false; },
    }
    val v = this.view_of(elem);
    val h = this.handle_of(elem);
    if (!given && v != STR && h == null) {
        // a slice of what C holds as it is: a Span
        return false;
    }
    a.decl = fmt2("{} {}", this.cs_ty(t), S(name));
    a.pass = fmt3("new {} {{ ptr = {}_p, len = (nuint){}_v.Length }}", this.made_name("slice", v, true), S(name0), S(name0));
    if (v == STR) {
        a.open = fmt3("var {}_t = new VoltStrs({});\ntry {{\nvar {}_v = ", S(name0), S(name), S(name0));
        a.open.append(fmt3("{}_t.Views;\nfixed (VoltStr* {}_p = {}_v) {{\n", S(name0), S(name0), S(name0)).as_str());
        a.close = fmt("}}\n}}\nfinally {{\n    {}_t.Dispose();\n}}\n", S(name0));
        return true;
    }
    if (h != null && !given) {
        // each kept alive (and unfreeable) for the call
        a.open = fmt3("var {}_l = new VoltHandles({}.Select(x => x.h));\ntry {{\nvar {}_v = ", S(name0), S(name), S(name0));
        a.open.append(fmt3("{}_l.Ptrs;\nfixed (IntPtr* {}_p = {}_v) {{\n", S(name0), S(name0), S(name0)).as_str());
        a.close = fmt("}}\n}}\nfinally {{\n    {}_l.Dispose();\n}}\n", S(name0));
        return true;
    }
    var conv: std::string = {};
    if (h != null) {
        conv = S(".Select(x => x.Release())");
    }
    match (this.shape_of(elem) ?? shape::VOID) {
        .BOOL => { conv = S(".Select(x => (byte)(x ? 1 : 0))"); },
        default => {},
    }
    a.open = fmt4("var {}_v = {}{}.ToArray();\nfixed ({}* ", S(name0), S(name), move conv, this.cs_raw(v));
    a.open.append(fmt2("{}_p = {}_v) {{\n", S(name0), S(name0)).as_str());
    a.close = S("}\n");
    return true;
}

// the C# value of C result r (of type t)
attach fn cs_value(this: bind&, t: u32, r: str) -> std::string {
    val lh = this.lent_handle(t);
    if (lh) {
        // a handle Volt lends: a class that never frees it
        val cls = this.local(this.c.si(lh).name);
        return fmt3("new {}(new {}Handle({}, false))", copy cls, copy cls, S(r));
    }
    match (this.shape_of(t) ?? shape::VOID) {
        .BOOL => { return fmt("{} != 0", S(r)); },
        .STR => { return fmt("VoltStr.Text({})", S(r)); },
        .CSTR => { return fmt("Marshal.PtrToStringUTF8((IntPtr){})", S(r)); },
        .TEXT(x) => { return fmt("VoltText.Take({})", S(r)); },
        .HANDLE(s) => { return fmt3("new {}(new {}Handle({}))", this.local(this.c.si(s).name), this.local(this.c.si(s).name), S(r)); },
        .OPT(x) => {
            if (this.handle_of(x) != null) {
                return fmt3("{} == IntPtr.Zero ? ({}?)null : {}", S(r), this.cs_elem(x), this.cs_value(x, r));
            }
            return fmt3("{}.has != 0 ? {} : ({}?)null", S(r), this.cs_value(x, fmt("{}.value", S(r)).as_str()), this.cs_elem(x));
        },
        .LIST(x) => {
            // copied into a List, and the list freed (each handle is the List's)
            var e = this.list_elem(t);
            if (this.view_of(e) == STR) {
                e = STR;
            }
            return fmt5("VoltList.Take({}.ptr, {}.len, {}.owner, {}.drop, x => {})", S(r), S(r), S(r), S(r), this.cs_value(e, "x"));
        },
        .CLOSURE(i) => { return fmt2("new closure{}({})", unum(@cast<u64>(i)), S(r)); },
        .TRAIT(i) => { return fmt2("new volt_{}({})", this.short(this.trait_of(t)), S(r)); },
        default => { return S(r); },
    }
}

// the C form of C# value v (of type t) a callback gives Volt back: text given (Volt frees it), a str
// kept, a handle given up
attach fn cs_give(this: bind&, t: u32, v: str) -> std::string {
    if (this.lent_handle(t) != null) {
        return fmt("{}.h.DangerousGetHandle()", S(v));
    }
    match (this.shape_of(t) ?? shape::VOID) {
        .BOOL => { return fmt("(byte)({} ? 1 : 0)", S(v)); },
        .STR => { return fmt("VoltStr.Keep({})", S(v)); },
        .TEXT(x) => { return fmt("VoltText.Give({})", S(v)); },
        .HANDLE(s) => { return fmt("{}.Release()", S(v)); },
        default => { return S(v); },
    }
}

// a C function Volt calls (a closure parameter's, or a trait's fn on a C# object), with the GCHandle
// of a Callback first and ps' C forms: it calls target with C# values and gives back r's C form; an
// error set's exception is E!T's error, any other is kept for after the call
attach fn cs_callback(this: bind&, name: str, target: str, ps: std::vec<u32>&, r: u32) -> std::string {
    var params = S("IntPtr user");
    var args: std::string = {};
    for (k) in 0..ps.len {
        val p = this.in_ty(*ps.at(k));
        val a = fmt("a{}", unum(@cast<u64>(k)));
        params.append(fmt2(", {} {}", this.cs_raw(p), copy a).as_str());
        if (k > 0) {
            args.append(", ");
        }
        args.append(this.cs_value(p, a.as_str()).as_str());
    }
    val raw = this.cs_raw(r);
    var out = fmt3("\n    [UnmanagedCallersOnly]\n    public static {} {}({})\n    {{\n        var c = (Callback)GCHandle.FromIntPtr(user).Target!;\n        try\n        {{\n", copy raw, S(name), move params);
    val call = fmt2("{}({})", S(target), move args);
    val v = this.cs_ok(r);
    val res = v != r;
    // what goes back when it throws (text has to be text Volt can free)
    var fallback = S("default");
    match (this.shape_of(v) ?? shape::VOID) {
        .TEXT(x) => { fallback = S("VoltText.Give(\"\")"); },
        default => {},
    }
    if (res && fallback.as_str() != "default") {
        fallback = fmt2("new {} {{ value = {} }}", copy raw, move fallback);
    }
    if (v == VOID) {
        out.append(fmt("            {};\n", copy call).as_str());
        if (res) {
            out.append("            return default;\n");
        }
    } else if (res) {
        out.append(fmt2("            return new {} {{ value = {} }};\n", copy raw, this.cs_give(v, call.as_str())).as_str());
    } else {
        out.append(fmt("            return {};\n", this.cs_give(r, call.as_str())).as_str());
    }
    out.append("        }\n");
    if (res) {
        out.append(fmt("        catch (VoltException e)\n        {{\n            return new {} {{ error = e.Code }};\n        }}\n", copy raw).as_str());
    }
    out.append("        catch (Exception e)\n        {\n            c.Error ??= e;\n");
    if (r != VOID) {
        out.append(fmt("            return {};\n", move fallback).as_str());
    }
    out.append("        }\n    }\n");
    return out;
}

// a wrapper's body: the call inside its parameters' blocks, the error check, the result
attach fn cs_body(this: bind&, f: u32, args: std::vec<cs_arg>&, ctor: bool) -> std::string {
    val info = this.c.fi(f);
    var made = this.makes(f);
    if (!ctor) {
        made = null;
    }
    return this.cs_call(fmt("Native.{}", cs_ident(info.c_name)), info.ret, args, made);
}

// callee called with args inside their blocks, its error thrown, its result as C# has it (made: the
// export struct whose handle a constructor keeps)
attach fn cs_call(this: bind&, callee: std::string, ret: u32, args: std::vec<cs_arg>&, made: u32?) -> std::string {
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
    var call = fmt2("{}({})", move callee, move passes);
    var body: std::string = {};
    var ret_decl: std::string = {};
    if (ret == VOID) {
        body = fmt("{};\n", move call);
    } else {
        ret_decl = fmt("{} result;\n", this.cs_ret(ret));
        if (made != null) {
            ret_decl = fmt("{}Handle result;\n", this.local(this.c.si(made ?? 0).name));
        }
        match (this.shape_of(ret) ?? shape::VOID) {
            .RESULT(e, x) => {
                body = fmt("var r = {};\nif (r.error != 0) {\n    throw VoltException.For(r.error);\n}\n", move call);
                if (x == VOID) {
                    ret_decl = {};
                } else if (made != null) {
                    body.append(fmt2("result = new {}Handle({});\n", this.local(this.c.si(made ?? 0).name), S("r.value")).as_str());
                } else {
                    body.append(fmt("result = {};\n", this.cs_value(x, "r.value")).as_str());
                }
            },
            default => {
                if (made != null) {
                    body = fmt2("var r = {};\nresult = new {}Handle(r);\n", move call, this.local(this.c.si(made ?? 0).name));
                } else {
                    body = fmt2("var r = {};\nresult = {};\n", move call, this.cs_value(ret, "r"));
                }
            },
        }
    }
    var out = move ret_decl;
    out.append(open.as_str());
    out.append(body.as_str());
    out.append(close.as_str());
    if (ret != VOID) {
        match (this.shape_of(ret) ?? shape::VOID) {
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

// a closure's or a trait fn's params (a0, a1...) as C# passes them to Volt
attach fn cs_sig_args(this: bind&, ps: std::vec<u32>&) -> std::vec<cs_arg> {
    var out: std::vec<cs_arg> = {};
    for (k) in 0..ps.len {
        var a: cs_arg = {};
        this.cs_arg_of(*ps.at(k), fmt("a{}", unum(@cast<u64>(k))).as_str(), &a);
        put(&out, move a);
    }
    return out;
}

// "public R name(A a0, ...)" calling Volt's C function callee with what the class holds (o_) first:
// a Volt closure's Invoke, or a method of volt_T
attach fn cs_call_out(this: bind&, name: str, callee: str, ps: std::vec<u32>&, r: u32) -> std::string {
    var args = this.cs_sig_args(ps);
    var all: std::vec<cs_arg> = {};
    put(&all, { decl: {}, pass: S("o_.self"), open: S("var o_ = O;\ntry {\n"), close: S("}\nfinally {\n    GC.KeepAlive(this);\n}\n") });
    for (a&) in args.items() {
        put(&all, copy *a);
    }
    var out = fmt3("\n    public {} {}({})\n    {{\n", this.cs_ty(r), S(name), cs_decls(&args));
    out.append(indent_n(this.cs_call(S(callee), r, &all, null).as_str(), 8).as_str());
    out.append("    }\n");
    return out;
}

// what a class holding o, a C struct Volt gave out, has: Dispose (or the finalizer) frees it once
// (o.drop), and O is it while it's alive (live: its field that's null once it's freed)
fn cs_owner(cls: str, raw: str, live: str) -> std::string {
    var out = fmt4("    {} o;\n    int freed;\n\n    internal {}({} o) => this.o = o;\n\n    ~{}() => Free();\n\n", S(raw), S(cls), S(raw), S(cls));
    out.append("    public void Dispose()\n    {\n        Free();\n        GC.SuppressFinalize(this);\n    }\n\n    void Free()\n    {\n        if (Interlocked.Exchange(ref freed, 1) != 0)\n        {\n            return;\n        }\n        var x = o;\n        o = default;\n        if (x.drop != null)\n        {\n            x.drop(x.self);\n        }\n    }\n\n");
    out.append(fmt3("    {} O => o.{} != null ? o : throw new ObjectDisposedException(nameof({}));\n", S(raw), S(live), S(cls)).as_str());
    return out;
}

// trait K in C#: an interface (implement it to hand Volt one), its C structs, the table Volt calls a
// C# object through, and volt_T, one Volt gave out
attach fn cs_trait(this: bind&, k: u32, out: std::string&) -> void {
    val t = *this.traits.at(k);
    val tn = this.short(t);
    val fns = this.fns_of(t);
    out.append(fmt4("\n/// <summary>trait {}: implement it to hand Volt a {} (lent, or given: Volt disposes it when it's\n/// done, when it's IDisposable); one Volt gives back is a volt_{}</summary>\npublic interface {}\n{{\n", this.c.ty_name(t), copy tn, copy tn, copy tn).as_str());
    for (f&) in fns.items() {
        var args = this.cs_sig_args(&f.params);
        out.append(fmt3("    {} {}({});\n", this.cs_ty(f.ret), cs_ident(f.name), cs_decls(&args)).as_str());
    }
    out.append("}\n");
    out.append(fmt2("\n/// <summary>trait {}'s fns, each taking the object first</summary>\n[StructLayout(LayoutKind.Sequential)]\npublic unsafe struct {}_vt\n{{\n", this.c.ty_name(t), copy tn).as_str());
    for (f&) in fns.items() {
        out.append(fmt2("    public {} {};\n", this.cs_fn_of(&f.params, f.ret), cs_ident(f.name)).as_str());
    }
    out.append("}\n");
    out.append(fmt3("\n/// <summary>a {} as C passes it: its table, the object, and what frees it (null: it's lent)</summary>\n[StructLayout(LayoutKind.Sequential)]\npublic unsafe struct {}_obj\n{{\n    public {}_vt* vt;\n    public IntPtr self;\n    public delegate* unmanaged<IntPtr, void> drop;\n}}\n", copy tn, copy tn, copy tn).as_str());
    // the table: a C function per fn, calling the C# object
    out.append(fmt4("\n// the table Volt calls a C# {} through (its self is a GCHandle to a Callback holding it)\ninternal static unsafe class {}_table\n{{\n    internal static readonly {}_vt* Vt = Make();\n\n    static {}_vt* Make()\n    {{\n", copy tn, copy tn, copy tn, copy tn).as_str());
    out.append(fmt2("        var vt = ({}_vt*)NativeMemory.Alloc((nuint)sizeof({}_vt));\n", copy tn, copy tn).as_str());
    for (f&) in fns.items() {
        out.append(fmt2("        vt->{} = &call_{};\n", cs_ident(f.name), S(f.name)).as_str());
    }
    out.append("        return vt;\n    }\n");
    for (f&) in fns.items() {
        out.append(this.cs_callback(fmt("call_{}", S(f.name)).as_str(), fmt2("(({})c.F).{}", copy tn, cs_ident(f.name)).as_str(), &f.params, f.ret).as_str());
    }
    out.append("\n    // Volt is done with one it was given: it's disposed, when it's IDisposable\n    [UnmanagedCallersOnly]\n    internal static void drop(IntPtr user)\n    {\n        var g = GCHandle.FromIntPtr(user);\n        var c = (Callback)g.Target!;\n        g.Free();\n        try\n        {\n            (c.F as IDisposable)?.Dispose();\n        }\n        catch (Exception e)\n        {\n            c.Error ??= e;\n        }\n    }\n}\n");
    // one Volt gave out
    out.append(fmt3("\n/// <summary>a {} Volt gave out: calls Volt's; Dispose (or the finalizer) frees it</summary>\npublic sealed unsafe class volt_{} : {}, IDisposable\n{{\n", copy tn, copy tn, copy tn).as_str());
    out.append(cs_owner(fmt("volt_{}", copy tn).as_str(), fmt("{}_obj", copy tn).as_str(), "vt").as_str());
    for (f&) in fns.items() {
        out.append(this.cs_call_out(cs_ident(f.name).as_str(), fmt("o_.vt->{}", cs_ident(f.name)).as_str(), &f.params, f.ret).as_str());
    }
    out.append("}\n");
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
    // the body first (the helpers it needs are added around it)
    var out: std::string = {};
    for (x&) in this.slices.items() {
        out.append(fmt2("\n/// <summary>a Volt slice: elements and how many</summary>\n[StructLayout(LayoutKind.Sequential)]\npublic unsafe struct {}\n{{\n    public {}* ptr;\n    public nuint len;\n}}\n", this.made_name("slice", *x, true), this.cs_raw(*x)).as_str());
    }
    for (lt&) in this.lists.items() {
        out.append(fmt3("\n/// <summary>{}, given out by a Volt function: its elements (lent), how many, and what frees them</summary>\n[StructLayout(LayoutKind.Sequential)]\npublic unsafe struct {}\n{{\n    public {}* ptr;\n    public nuint len;\n    public IntPtr owner;\n    public delegate* unmanaged<IntPtr, void> drop;\n}}\n", this.c.ty_name(*lt), this.cs_raw(*lt), this.cs_raw(this.view_of(this.list_elem(*lt)))).as_str());
    }
    for (x&) in this.opts.items() {
        val n = this.made_name("opt", *x, true);
        out.append(fmt2("\n/// <summary>a Volt optional: has (0 or 1) says whether value is there</summary>\n[StructLayout(LayoutKind.Sequential)]\npublic struct {}\n{{\n    public {} value;\n    public byte has;\n", copy n, this.cs_raw(*x)).as_str());
        var plain_value = this.simple_value(*x);
        match (this.shape_of(*x) ?? shape::VOID) {
            .BOOL => { plain_value = false; },
            default => {},
        }
        if (plain_value) {
            // so a T? is one (in a slice of them)
            out.append(fmt3("\n    public static implicit operator {}({}? v) => new {} {{ value = v.GetValueOrDefault(), has = (byte)(v.HasValue ? 1 : 0) }};\n", copy n, this.cs_raw(*x), copy n).as_str());
        }
        out.append("}\n");
    }
    // errors: one exception class per error set, holding its codes too
    out.append("\n/// <summary>an error a Volt function returned: its code and name</summary>\npublic class VoltException : Exception\n{\n    public uint Code { get; }\n    public string Name { get; }\n\n    public VoltException(uint code, string name) : base(name)\n    {\n        Code = code;\n        Name = name;\n    }\n\n    /// <summary>the exception for an error code (a callback throws it to give Volt that error)</summary>\n    public static VoltException For(uint code)\n    {\n        switch (code)\n        {\n");
    for (c&) in this.all_codes().items() {
        out.append(fmt3("            case {}u: return new {}(code, \"{}\");\n", num(c.code), copy c.set, S(c.name)).as_str());
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
    // a closure Volt gives out: its C struct, and a class that calls it (Invoke) and frees it
    for (i) in 0..this.closures.len {
        if (!has_u32(&this.closures_out, @cast<u32>(i))) {
            continue;
        }
        val ct = *this.closures.at(i);
        val n = fmt("closure{}", unum(@cast<u64>(i)));
        var ps: std::vec<u32> = {};
        val r = this.fn_parts(ct, &ps);
        out.append(fmt3("\n/// <summary>{}, given out by Volt: call(self, ...) calls it, drop(self) frees it</summary>\n[StructLayout(LayoutKind.Sequential)]\npublic unsafe struct {}_obj\n{{\n    public {} call;\n    public IntPtr self;\n    public delegate* unmanaged<IntPtr, void> drop;\n}}\n", this.c.ty_name(ct), copy n, this.cs_fnptr(ct)).as_str());
        out.append(fmt2("\n/// <summary>{}, given out by Volt: Invoke calls it; Dispose (or the finalizer) frees it</summary>\npublic sealed unsafe class {} : IDisposable\n{{\n", this.c.ty_name(ct), copy n).as_str());
        out.append(cs_owner(n.as_str(), fmt("{}_obj", copy n).as_str(), "call").as_str());
        out.append(this.cs_call_out("Invoke", "o_.call", &ps, r).as_str());
        out.append("}\n");
    }
    for (k) in 0..this.traits.len {
        this.cs_trait(@cast<u32>(k), &out);
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
            ret = this.cs_out(f.ret);
            for (p&) in f.params.items() {
                if (ps.len() > 0) {
                    ps.append(", ");
                }
                ps.append(fmt2("{} {}", this.cs_raw(this.in_ty(p.ty)), cs_ident(p.name)).as_str());
                match (this.shape_of(p.ty) ?? shape::VOID) {
                    .CLOSURE(i) => { ps.append(fmt(", IntPtr {}_user", S(p.name)).as_str()); },
                    default => {},
                }
            }
        }
        out.append(fmt4("\n    [LibraryImport(Lib, EntryPoint = \"{}\")]\n    public static partial {} {}({});\n", copy e.name, move ret, cs_ident(e.name.as_str()), move ps).as_str());
    }
    out.append("}\n");
    // callbacks: the C functions a closure parameter calls, which call the delegate
    if (this.closures.len > 0) {
        out.append("\ninternal static unsafe class Callbacks\n{");
        for (i) in 0..this.closures.len {
            val ct = *this.closures.at(i);
            var ps: std::vec<u32> = {};
            val r = this.fn_parts(ct, &ps);
            out.append(this.cs_callback(fmt("cb{}", unum(@cast<u64>(i))).as_str(), fmt("(({})c.F)", this.cs_ty(ct)).as_str(), &ps, r).as_str());
        }
        out.append("}\n");
    }
    // a class per export struct, over a SafeHandle
    for (s&) in this.handles.items() {
        val cls = this.local(this.c.si(*s).name);
        out.append(fmt4("\n/// <summary>owns a handle to export struct {}; Dispose (or a using block, or the finalizer) frees it</summary>\npublic sealed class {}Handle : SafeHandle\n{{\n    public {}Handle() : base(IntPtr.Zero, true) {{ }}\n    public {}Handle(IntPtr h) : base(IntPtr.Zero, true) => SetHandle(h);\n", S(this.c.si(*s).name), copy cls, copy cls, copy cls).as_str());
        out.append(fmt("    // one Volt lends (owns: false) is never freed through this\n    public {}Handle(IntPtr h, bool owns) : base(IntPtr.Zero, owns) => SetHandle(h);\n", copy cls).as_str());
        out.append(fmt("    public override bool IsInvalid => handle == IntPtr.Zero;\n\n    protected override bool ReleaseHandle()\n    {\n        Native.{}(handle);\n        return true;\n    }\n}\n", cs_ident(this.free_name(*s).as_str())).as_str());
        out.append(fmt3("\n/// <summary>export struct {}</summary>\npublic sealed unsafe class {} : IDisposable\n{{\n    internal readonly {}Handle h;\n\n", S(this.c.si(*s).name), copy cls, copy cls).as_str());
        out.append(fmt2("    public {}({}Handle h) => this.h = h;\n\n    public void Dispose() => h.Dispose();\n", copy cls, copy cls).as_str());
        out.append(fmt("\n    /// <summary>gives the handle up (to Volt, or to free it yourself): this no longer frees it</summary>\n    public IntPtr Release()\n    {{\n        if (h.IsClosed || h.IsInvalid)\n        {{\n            throw new ObjectDisposedException(nameof({}));\n        }}\n        var p = h.DangerousGetHandle();\n        h.SetHandleAsInvalid();\n        return p;\n    }}\n", copy cls).as_str());
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
                out.append(fmt3("    public {} {}({})\n    {{\n", this.cs_ret(info.ret), cs_ident(m), cs_decls(&args)).as_str());
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
                out.append(fmt3("    public static {} {}({})\n    {{\n", this.cs_ret(info.ret), cs_ident(m), cs_decls(&args)).as_str());
                out.append(indent_n(this.cs_body(e.f, &args, false).as_str(), 8).as_str());
                out.append("    }\n");
            }
        }
        out.append("}\n");
    }
    // the functions
    out.append("\n/// <summary>the package's functions</summary>\npublic static unsafe class Api\n{\n");
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
        out.append(fmt3("    public static {} {}({})\n    {{\n", this.cs_ret(info.ret), cs_ident(info.c_name), cs_decls(&args)).as_str());
        out.append(indent_n(this.cs_body(e.f, &args, false).as_str(), 8).as_str());
        out.append("    }\n");
    }
    out.append("}\n");
    // the helpers the body uses
    if (this.closures.len > 0 || this.traits.len > 0) {
        out.append("\n// a delegate or an object Volt calls, and what it threw (rethrown after the call)\ninternal sealed class Callback\n{\n    public readonly object F;\n    public Exception? Error;\n\n    public Callback(object f) => F = f;\n\n    public void Rethrow()\n    {\n        if (Error != null)\n        {\n            System.Runtime.ExceptionServices.ExceptionDispatchInfo.Capture(Error).Throw();\n        }\n    }\n}\n");
    }
    if (contains(out.as_str(), "VoltList.Take(")) {
        out.append("\n// copies a list a Volt function gave out, and frees it\ninternal static unsafe class VoltList\n{\n    public static List<U> Take<T, U>(T* ptr, nuint len, IntPtr owner, delegate* unmanaged<IntPtr, void> drop, Func<T, U> f) where T : unmanaged\n    {\n        var v = new List<U>((int)len);\n        for (nuint i = 0; i < len; i++)\n        {\n            v.Add(f(ptr[i]));\n        }\n        if (drop != null)\n        {\n            drop(owner);\n        }\n        return v;\n    }\n}\n");
    }
    if (contains(out.as_str(), "new VoltStrs(")) {
        out.append("\n// text lent to Volt for one call: each string's UTF-8 bytes, in one block Dispose frees\ninternal sealed unsafe class VoltStrs : IDisposable\n{\n    byte* p;\n    public readonly VoltStr[] Views;\n\n    public VoltStrs(IEnumerable<string> xs)\n    {\n        var bs = xs.Select(x => Encoding.UTF8.GetBytes(x)).ToArray();\n        var n = 0;\n        foreach (var b in bs)\n        {\n            n += b.Length;\n        }\n        p = (byte*)NativeMemory.Alloc((nuint)n + 1);\n        Views = new VoltStr[bs.Length];\n        var at = p;\n        for (var i = 0; i < bs.Length; i++)\n        {\n            bs[i].CopyTo(new Span<byte>(at, bs[i].Length));\n            Views[i] = new VoltStr { ptr = at, len = (nuint)bs[i].Length };\n            at += bs[i].Length;\n        }\n    }\n\n    public void Dispose()\n    {\n        NativeMemory.Free(p);\n        p = null;\n    }\n}\n");
    }
    if (contains(out.as_str(), "new VoltHandles(")) {
        out.append("\n// handles lent to Volt for one call: each kept alive (and unfreeable) until Dispose\ninternal sealed class VoltHandles : IDisposable\n{\n    readonly SafeHandle[] hs;\n    readonly bool[] refs;\n    public readonly IntPtr[] Ptrs;\n\n    public VoltHandles(IEnumerable<SafeHandle> xs)\n    {\n        hs = xs.ToArray();\n        refs = new bool[hs.Length];\n        Ptrs = new IntPtr[hs.Length];\n        try\n        {\n            for (var i = 0; i < hs.Length; i++)\n            {\n                hs[i].DangerousAddRef(ref refs[i]);\n                Ptrs[i] = hs[i].DangerousGetHandle();\n            }\n        }\n        catch\n        {\n            Dispose();\n            throw;\n        }\n    }\n\n    public void Dispose()\n    {\n        for (var i = 0; i < hs.Length; i++)\n        {\n            if (refs[i])\n            {\n                hs[i].DangerousRelease();\n                refs[i] = false;\n            }\n        }\n    }\n}\n");
    }
    // the head, and the shared types
    var head = fmt("// {}: generated by voltc bindings; the Volt package for C# (.NET 7 or later). It calls\n", S(this.pkg));
    head.append(fmt2("// lib{}.so (or {}.dll, lib", S(this.pkg), S(this.pkg)).as_str());
    head.append(fmt("{}.dylib) through LibraryImport; build with AllowUnsafeBlocks. Errors are thrown as\n// VoltException, one subclass per error set.\n", S(this.pkg)).as_str());
    head.append("#nullable enable\n#pragma warning disable CS8981 // the type names are Volt's (lower case)\nusing System;\nusing System.Collections.Generic;\nusing System.Linq;\nusing System.Runtime.CompilerServices;\nusing System.Runtime.InteropServices;\nusing System.Text;\nusing System.Threading;\n\n");
    head.append(fmt("namespace {};\n", S(this.pkg)).as_str());
    head.append("\n/// <summary>a Volt str: UTF-8 bytes and a length</summary>\n[StructLayout(LayoutKind.Sequential)]\npublic unsafe struct VoltStr\n{\n    public byte* ptr;\n    public nuint len;\n\n    public static string Text(VoltStr s) => Encoding.UTF8.GetString(s.ptr, (int)s.len);\n");
    if (contains(out.as_str(), "VoltStr.Keep(")) {
        // ponytail: kept for good, like a 'static str (once per distinct text); free them after each
        // call if callbacks give back many different strs
        head.append("\n    static readonly Dictionary<string, VoltStr> kept = new();\n\n    // a str C# gives Volt back (a callback's result): its bytes are kept for good, once per text\n    public static VoltStr Keep(string s)\n    {\n        lock (kept)\n        {\n            if (!kept.TryGetValue(s, out var v))\n            {\n                var b = Encoding.UTF8.GetBytes(s);\n                v = new VoltStr { ptr = (byte*)NativeMemory.Alloc((nuint)b.Length + 1), len = (nuint)b.Length };\n                b.CopyTo(new Span<byte>(v.ptr, b.Length));\n                v.ptr[b.Length] = 0;\n                kept[s] = v;\n            }\n            return v;\n        }\n    }\n");
    }
    head.append("}\n");
    if (this.texts.len > 0) {
        head.append("\n/// <summary>owned text a Volt function gave out (the wrappers copy it into a string and free it)</summary>\n[StructLayout(LayoutKind.Sequential)]\npublic unsafe struct VoltText\n{\n    public byte* ptr;\n    public nuint len;\n    public IntPtr owner;\n    public delegate* unmanaged<IntPtr, void> drop;\n\n    public static string Take(VoltText t)\n    {\n        string s = Encoding.UTF8.GetString(t.ptr, (int)t.len);\n        if (t.drop != null)\n        {\n            t.drop(t.owner);\n        }\n        return s;\n    }\n");
        if (contains(out.as_str(), "VoltText.Give(")) {
            head.append("\n    // text C# gives Volt (a callback's result): Volt frees it when it's done\n    public static VoltText Give(string s)\n    {\n        var b = Encoding.UTF8.GetBytes(s);\n        var p = (byte*)NativeMemory.Alloc((nuint)b.Length + 1);\n        b.CopyTo(new Span<byte>(p, b.Length));\n        return new VoltText { ptr = p, len = (nuint)b.Length, owner = (IntPtr)p, drop = &Free };\n    }\n\n    [UnmanagedCallersOnly]\n    static void Free(IntPtr p) => NativeMemory.Free((void*)p);\n");
        }
        head.append("}\n");
    }
    head.append(out.as_str());
    return head;
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
        .LIST(x) => { return { size: 32, align: 8 }; },
        .TRAIT(i) => { return { size: 24, align: 8 }; },
        .CLOSURE(i) => { return { size: 24, align: 8 }; },
        .ARRAY(elem, n) => {
            val e = this.csize(elem);
            return { size: e.size * n, align: e.align };
        },
        .STRUCT(s) => { return this.struct_size(s); },
        .OPT(x) => {
            if (this.handle_of(x) != null) {
                return { size: 8, align: 8 };
            }
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
        .OPT(x) => { return this.handle_of(x) == null; },
        .RESULT(e, x) => { return true; },
        .LIST(x) => { return true; },
        .TRAIT(i) => { return true; },
        .CLOSURE(i) => { return true; },
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
        .LIST(x) => { return S("L_LIST"); },
        .TRAIT(i) => { return S("L_OBJ"); },
        .CLOSURE(i) => { return S("L_OBJ"); },
        .ARRAY(elem, n) => { return fmt2("MemoryLayout.sequenceLayout({}, {})", unum(n), this.java_layout(elem)); },
        .OPT(x) => {
            // an optional handle is its pointer
            if (this.handle_of(x) != null) {
                return S("ADDRESS");
            }
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
        .LIST(x) => { return fmt("{}[]", this.java_ty(this.view_of(this.list_elem(x)), false)); },
        .OPT(x) => { return this.java_ty(x, true); },
        .RESULT(e, x) => { return this.java_ty(x, boxed); },
        .TRAIT(i) => { return fmt("volt_{}", this.short(this.trait_of(t))); },
        .CLOSURE(i) => { return fmt("Closure{}", unum(@cast<u64>(i))); },
        default => { return S("MemorySegment"); },
    }
}

// the Java expression for a value of type t read from segment seg at offset off
attach fn java_read(this: bind&, t: u32, seg: str, off: u64) -> std::string {
    match (this.shape_of(t) ?? shape::VOID) {
        .STRUCT(s) => { return fmt3("{}.read({}.asSlice({}))", this.local(this.c.si(s).name), S(seg), unum(off)); },
        .STR => { return fmt2("text({}.asSlice({}, L_STR))", S(seg), unum(off)); },
        .TEXT(x) => { return fmt2("take({}.asSlice({}, L_TEXT))", S(seg), unum(off)); },
        .HANDLE(h) => { return fmt3("new {}({}.get(ADDRESS, {}))", this.local(this.c.si(h).name), S(seg), unum(off)); },
        .OPT(x) => { return fmt3("({}.get(JAVA_BOOLEAN, {}) ? {} : null)", S(seg), unum(off + this.csize(x).size), this.java_read(x, seg, off)); },
        .ENUM(e) => { return fmt4("{}.of({}.get({}, {}))", this.local(this.c.ei(e).name), S(seg), this.java_vl(t), unum(off)); },
        default => { return fmt3("{}.get({}, {})", S(seg), this.java_vl(t), unum(off)); },
    }
}

// the Java statement writing value v (of type t) into segment seg at offset off
attach fn java_write(this: bind&, t: u32, seg: str, off: u64, v: str) -> std::string {
    match (this.shape_of(t) ?? shape::VOID) {
        .STRUCT(s) => { return fmt3("{}.write({}.asSlice({}));", S(v), S(seg), unum(off)); },
        .OPT(x) => {
            var w = fmt3("if ({} != null) {{\n    {}\n    {}", S(v), this.java_write(x, seg, off, v), S(seg));
            w.append(fmt(".set(JAVA_BOOLEAN, {}, true);\n}", unum(off + this.csize(x).size)).as_str());
            return w;
        },
        .ENUM(e) => { return fmt4("{}.set({}, {}, {}.value);", S(seg), this.java_vl(t), unum(off), S(v)); },
        default => { return fmt4("{}.set({}, {}, {});", S(seg), this.java_vl(t), unum(off), S(v)); },
    }
}

// can a value of type t be a field of a Java mirror class, an array element, or a callback argument
attach fn java_simple(this: bind&, t: u32) -> bool {
    match (this.shape_of(t) ?? shape::VOID) {
        .BOOL => { return true; },
        .OPT(x) => { return this.handle_of(x) == null && this.java_simple(x); },
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
        a.after = fmt("java.lang.ref.Reference.reachabilityFence({});\n", S(name));
        return;
    }
    match (this.shape_of(t) ?? shape::VOID) {
        .STR => {
            a.decl = fmt("String {}", S(name));
            a.before = fmt2("MemorySegment {}_s = str(arena, {});\n", S(name), S(name));
            a.pass = fmt("{}_s", S(name));
        },
        .TEXT(x) => {
            // owned text in: Volt copies it
            a.decl = fmt("String {}", S(name));
            a.before = fmt2("MemorySegment {}_s = str(arena, {});\n", S(name), S(name));
            a.pass = fmt("{}_s", S(name));
        },
        .HANDLE(h) => {
            // given to Volt, which frees it
            a.decl = fmt2("{} {}", this.local(this.c.si(h).name), S(name));
            a.pass = fmt("{}.release()", S(name));
        },
        .TRAIT(i) => {
            // a Java object (lent for the call, or given: Volt closes it when it's done), or Volt's own
            val tr = this.short(this.trait_of(t));
            var given = S("true");
            if (this.is_ref(t)) {
                given = S("false");
            }
            a.decl = fmt2("{} {}", copy tr, S(name));
            a.before = fmt4("MemorySegment {}_o = {}_obj(arena, {}, {});\n", S(name), copy tr, S(name), move given);
            a.pass = fmt("{}_o", S(name));
            if (this.is_ref(t)) {
                a.after = fmt2("forget({}_o);\njava.lang.ref.Reference.reachabilityFence({});\n", S(name), S(name));
            }
        },
        .LIST(x) => {
            // given to Volt, which copies the elements (and takes the handles)
            if (!this.java_elems(this.list_elem(t), true, name, a)) {
                this.java_arg_of(this.in_ty(t), name, a);
            }
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
            if (this.java_elems(x, false, name, a)) {
                return;
            }
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
            val h = this.handle_of(x);
            if (h) {
                // given to Volt, which frees it
                a.decl = fmt2("{} {}", this.local(this.c.si(h).name), S(name));
                // (a local: invokeExact would take the conditional itself as an Object)
                a.before = fmt3("MemorySegment {}_p = {} == null ? MemorySegment.NULL : {}.release();\n", S(name), S(name), S(name));
                a.pass = fmt("{}_p", S(name));
                return;
            }
            if (this.in_ty(x) == STR) {
                // str? or an optional text (Volt copies it)
                a.decl = fmt("String {}", S(name));
                a.before = fmt2("MemorySegment {}_s = arena.allocate({});\n", S(name), this.java_layout(this.in_ty(t)));
                a.before.append(fmt4("if ({} != null) {{\n    MemorySegment.copy(str(arena, {}), 0, {}_s, 0, 16);\n    {}_s.set(JAVA_BOOLEAN, 16, true);\n}}\n", S(name), S(name), S(name), S(name)).as_str());
                a.pass = fmt("{}_s", S(name));
                return;
            }
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

// a slice or a list of text, handles or optionals (true when x, the element as C sees it, is one):
// text from a String[], handles from an array of their classes (lent, or given up), optionals from
// an array of boxed values (null: none)
attach fn java_elems(this: bind&, x: u32, given: bool, name: str, a: java_arg&) -> bool {
    val e = this.view_of(x);
    val h = this.handle_of(x);
    var put = S("");
    var decl = S("");
    if (e == STR) {
        decl = S("String");
        put = fmt3("MemorySegment.copy(str(arena, {}[i]), 0, {}_e, i * 16L, 16);", S(name), S(name), S(""));
    } else if (h) {
        decl = this.local(this.c.si(h).name);
        var how = S("handle");
        if (given) {
            how = S("release");
        }
        put = fmt3("{}_e.setAtIndex(ADDRESS, i, {}[i].{}());", S(name), S(name), move how);
    } else {
        match (this.shape_of(e) ?? shape::VOID) {
            .OPT(v) => {
                decl = this.java_ty(e, false);
                put = this.java_write(e, fmt2("{}_e.asSlice(i * {}L)", S(name), unum(this.csize(e).size)).as_str(), 0, fmt("{}[i]", S(name)).as_str());
            },
            default => { return false; },
        }
    }
    val z = this.csize(e);
    a.decl = fmt3("{}[] {}", move decl, S(name), S(""));
    a.before = fmt4("MemorySegment {}_e = arena.allocate({}L * Math.max(1, {}.length), {});\n", S(name), unum(z.size), S(name), unum(z.align));
    if (h != null && given) {
        // each there before any is given up
        a.before.append(fmt("for (var x : {}) {{\n    java.util.Objects.requireNonNull(x);\n}}\n", S(name)).as_str());
    }
    a.before.append(fmt2("for (int i = 0; i < {}.length; i++) {{\n    {}\n}}\n", S(name), move put).as_str());
    a.before.append(fmt3("MemorySegment {}_s = arena.allocate(L_SLICE);\n{}_s.set(ADDRESS, 0, {}_e);\n", S(name), S(name), S(name)).as_str());
    a.before.append(fmt2("{}_s.set(JAVA_LONG, 8, {}.length);\n", S(name), S(name)).as_str());
    a.pass = fmt("{}_s", S(name));
    if (h != null && !given) {
        a.after = fmt("java.lang.ref.Reference.reachabilityFence({});\n", S(name));
    }
    return true;
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
            default => { args.append(this.java_layout(this.in_ty(p.ty)).as_str()); },
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
            val h = this.handle_of(x);
            if (h) {
                return fmt3("({}.equals(MemorySegment.NULL) ? null : new {}({}))", S(r), this.local(this.c.si(h).name), S(r));
            }
            return fmt3("({}.get(JAVA_BOOLEAN, {}) ? {} : null)", S(r), unum(this.csize(x).size), this.java_read(x, r, 0));
        },
        .LIST(x) => { return fmt2("list_{}({})", index_of(&this.lists, t), S(r)); },
        .TRAIT(i) => { return fmt2("new volt_{}({})", this.short(this.trait_of(t)), S(r)); },
        .CLOSURE(i) => { return fmt2("new Closure{}({})", unum(@cast<u64>(i)), S(r)); },
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
    return this.java_call(info.ret, fmt("H_{}", S(info.c_name)).as_str(), args, self_pass);
}

// a call of method handle callee (returning ret) with args after self_pass: the arena they're made
// in, the call, its error thrown and its value returned
attach fn java_call(this: bind&, ret: u32, callee: str, args: std::vec<java_arg>&, self_pass: str?) -> std::string {
    var passes: std::string = {};
    var before: std::string = {};
    var after: std::string = {};
    if (this.java_is_struct(ret)) {
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
    var body: std::string = {};
    val call = fmt2("{}.invokeExact({})", S(callee), move passes);
    if (ret == VOID) {
        body.append(fmt("{};\n", move call).as_str());
    } else {
        body.append(fmt2("var r = ({}) {};\n", this.java_carrier(ret), move call).as_str());
    }
    match (this.shape_of(ret) ?? shape::VOID) {
        .RESULT(e, x) => {
            body.append("int code = r.get(JAVA_INT, 0);\nif (code != 0) {\n    throw VoltException.of(code);\n}\n");
            if (x != VOID) {
                val off = align_to(4, this.csize(x).align);
                var v = this.java_read(x, "r", off);
                match (this.shape_of(x) ?? shape::VOID) {
                    .LIST(y) => { v = this.java_value(x, fmt2("r.asSlice({}, {})", unum(off), this.java_layout(x)).as_str()); },
                    .TRAIT(y) => { v = this.java_value(x, fmt2("r.asSlice({}, {})", unum(off), this.java_layout(x)).as_str()); },
                    .CLOSURE(y) => { v = this.java_value(x, fmt2("r.asSlice({}, {})", unum(off), this.java_layout(x)).as_str()); },
                    .OPT(y) => {
                        if (this.handle_of(y) != null) {
                            v = this.java_value(x, fmt("r.get(ADDRESS, {})", unum(off)).as_str());
                        }
                    },
                    default => {},
                }
                body.append(fmt("return {};\n", move v).as_str());
            }
        },
        .VOID => {},
        default => { body.append(fmt("return {};\n", this.java_value(ret, "r")).as_str()); },
    }
    // what follows the call runs even when it gives an error: lent objects forgotten, slices'
    // elements read back, what a callback or a trait fn threw rethrown
    if (this.traits.len > 0) {
        after.append("thrown();\n");
    }
    if (sp) {
        after.append("java.lang.ref.Reference.reachabilityFence(this);\n");
    }
    var out = S("try (Arena arena = Arena.ofConfined()) {\n");
    out.append(indent(before.as_str()).as_str());
    if (after.len() > 0) {
        out.append(fmt2("    try {{\n{}    }} finally {{\n{}    }}\n", indent(indent(body.as_str()).as_str()), indent(indent(after.as_str()).as_str())).as_str());
    } else {
        out.append(indent(body.as_str()).as_str());
    }
    out.append("} catch (RuntimeException | Error e) {\n    throw e;\n} catch (Throwable e) {\n    throw new RuntimeException(e);\n}\n");
    return out;
}

// the Java value of C argument a (of type t) an upcall gets: text as a String, a handle Volt gives
// as its class, one it lends as a class that never frees it
attach fn java_from_c(this: bind&, t: u32, a: str) -> std::string {
    val h = this.lent_handle(t);
    if (h) {
        return fmt2("new {}({}, false)", this.local(this.c.si(h).name), S(a));
    }
    match (this.shape_of(t) ?? shape::VOID) {
        .ENUM(e) => { return fmt2("{}.of({})", this.local(this.c.ei(e).name), S(a)); },
        .STR => { return fmt("text({}.reinterpret(L_STR.byteSize()))", S(a)); },
        .TEXT(x) => { return fmt("text({}.reinterpret(L_STR.byteSize()))", S(a)); },
        .STRUCT(s) => { return fmt2("{}.read({})", this.local(this.c.si(s).name), S(a)); },
        .HANDLE(s) => { return fmt2("new {}({})", this.local(this.c.si(s).name), S(a)); },
        default => { return S(a); },
    }
}

// statements writing Java's v (of type t) into seg at off as C takes it back: text given (Volt frees
// it), a handle given up
attach fn java_put(this: bind&, t: u32, seg: str, off: u64, v: str) -> std::string {
    match (this.shape_of(t) ?? shape::VOID) {
        .TEXT(x) => { return fmt4("MemorySegment.copy(give({}), 0, {}, {}, 32);", S(v), S(seg), unum(off), S("")); },
        .HANDLE(h) => { return fmt3("{}.set(ADDRESS, {}, {}.release());", S(seg), unum(off), S(v)); },
        default => { return this.java_write(t, seg, off, v); },
    }
}

// an upcall's statements returning call (Java's result, of type r) to C: text given, a handle given
// up, E!T as its struct (a VoltException thrown is its error)
attach fn java_to_c(this: bind&, r: u32, call: str) -> std::string {
    if (r == VOID) {
        return fmt("{};\n", S(call));
    }
    match (this.shape_of(r) ?? shape::VOID) {
        .ENUM(e) => { return fmt2("return ({}) {}.value;\n", this.java_carrier(r), S(call)); },
        .STR => { return fmt("return keep(str(Arena.ofAuto(), {}));\n", S(call)); },
        .TEXT(x) => { return fmt("return give({});\n", S(call)); },
        .HANDLE(s) => { return fmt("return {}.release();\n", S(call)); },
        .STRUCT(s) => { return fmt2("MemorySegment s = Arena.ofAuto().allocate(L_{});\n{}.write(s);\nreturn s;\n", this.local(this.c.si(s).name), S(call)); },
        .RESULT(e, x) => {
            var out = fmt("MemorySegment s = Arena.ofAuto().allocate({});\ntry {\n", this.java_layout(r));
            if (x == VOID) {
                out.append(fmt("    {};\n", S(call)).as_str());
            } else {
                out.append(fmt("    var v = {};\n", S(call)).as_str());
                out.append(fmt("    {}\n", this.java_put(x, "s", align_to(4, this.csize(x).align), "v")).as_str());
            }
            out.append("} catch (VoltException e) {\n    s.set(JAVA_INT, 0, e.code);\n}\nreturn s;\n");
            return out;
        },
        default => { return fmt("return {};\n", S(call)); },
    }
}

// what an upcall gives C when its Java code threw (the exception is rethrown after the call)
attach fn java_zero(this: bind&, r: u32) -> std::string {
    match (this.shape_of(r) ?? shape::VOID) {
        .BOOL => { return S("false"); },
        .TEXT(x) => { return S("give(\"\")"); },
        default => {},
    }
    if (this.java_is_struct(r)) {
        return fmt("Arena.ofAuto().allocate({})", this.java_layout(r));
    }
    val c = this.java_carrier(r);
    if (c.as_str() == "MemorySegment") {
        return S("MemorySegment.NULL");
    }
    if (c.as_str() == "int") {
        return S("0");
    }
    return fmt("({}) 0", move c);
}

// the method type and descriptor of an upcall taking self (when it has one) then ps, giving r
attach fn java_up_types(this: bind&, ps: std::vec<u32>&, r: u32, mt: std::string&, desc: std::string&) -> void {
    var vls: std::string = {};
    for (p&) in ps.items() {
        mt.append(fmt(", {}.class", this.java_carrier(this.in_ty(*p))).as_str());
        vls.append(", ");
        vls.append(this.java_layout(this.in_ty(*p)).as_str());
    }
    if (r == VOID) {
        desc.append(fmt("FunctionDescriptor.ofVoid(ADDRESS{})", move vls).as_str());
    } else {
        desc.append(fmt2("FunctionDescriptor.of({}, ADDRESS{})", this.java_layout(r), move vls).as_str());
    }
}

// trait K: a Java interface; its table of upcalls into a Java object (behind an id), what makes the
// object Volt takes, and volt_T, Volt's own value of it
attach fn java_trait(this: bind&, k: u32, out: std::string&) -> void {
    val t = *this.traits.at(k);
    val tr = this.short(t);
    val fns = this.fns_of(t);
    val cls = this.pkg;
    var iface: std::string = {};
    var ups: std::string = {};
    var table: std::string = {};
    var calls: std::string = {};
    for (j) in 0..fns.len {
        val f = fns.at(j);
        val jj = unum(@cast<u64>(j) * 8);
        var params: std::string = {};
        var cparams = S("MemorySegment self");
        var largs: std::string = {};
        var args: std::vec<java_arg> = {};
        for (q) in 0..f.params.len {
            val p = *f.params.at(q);
            val qq = unum(@cast<u64>(q));
            if (q > 0) {
                params.append(", ");
                largs.append(", ");
            }
            params.append(fmt2("{} a{}", this.java_ty(p, false), copy qq).as_str());
            cparams.append(fmt2(", {} a{}", this.java_carrier(this.in_ty(p)), copy qq).as_str());
            largs.append(this.java_from_c(p, fmt("a{}", copy qq).as_str()).as_str());
            var ja: java_arg = {};
            this.java_arg_of(p, fmt("a{}", copy qq).as_str(), &ja);
            put(&args, move ja);
        }
        val jr = this.java_ty(f.ret, false);
        iface.append(fmt3("        {} {}({});\n", copy jr, java_ident(f.name), copy params).as_str());
        var target_ret = this.java_carrier(f.ret);
        var mt = fmt("{}.class, MemorySegment.class", this.java_carrier(f.ret));
        if (f.ret == VOID) {
            target_ret = S("void");
            mt = S("void.class, MemorySegment.class");
        }
        var desc: std::string = {};
        this.java_up_types(&f.params, f.ret, &mt, &desc);
        ups.append(fmt4("\n    private static {} {}_{}({}) {{\n", move target_ret, copy tr, S(f.name), move cparams).as_str());
        ups.append(fmt2("        try {{\n            var o = ({}) OBJECTS.get(self.address());\n{}", copy tr, indent(indent(indent(this.java_to_c(f.ret, fmt2("o.{}({})", java_ident(f.name), copy largs).as_str()).as_str()).as_str()).as_str())).as_str());
        ups.append("        } catch (Throwable t) {\n            if (THROWN.get() == null) {\n                THROWN.set(t);\n            }\n");
        if (f.ret != VOID) {
            ups.append(fmt("            return {};\n", this.java_zero(f.ret)).as_str());
        }
        ups.append("        }\n    }\n");
        table.append(fmt4("            vt.set(ADDRESS, {}, LINKER.upcallStub(l.findStatic({}.class, \"{}_{}\", ", copy jj, S(cls), copy tr, S(f.name)).as_str());
        table.append(fmt2("MethodType.methodType({})), {}, Arena.global()));\n", move mt, copy desc).as_str());
        calls.append(fmt3("\n        public {} {}({}) {{\n", copy jr, java_ident(f.name), copy params).as_str());
        calls.append(fmt3("            MethodHandle h = LINKER.downcallHandle(o.get(ADDRESS, 0).reinterpret({}L).get(ADDRESS, {}), {});\n", unum(@cast<u64>(fns.len) * 8), copy jj, move desc).as_str());
        calls.append(indent(indent(indent(this.java_call(f.ret, "h", &args, "o.get(ADDRESS, 8)").as_str()).as_str()).as_str()).as_str());
        calls.append("        }\n");
    }
    out.append(fmt4("\n    /** trait {}: implement it in Java (lent or given to Volt, which closes a given AutoCloseable when\n     * it's done with it), or call Volt's own (volt_{}) */\n    public interface {} {{\n{}    }}\n", this.c.ty_name(t), copy tr, copy tr, move iface).as_str());
    out.append(ups.as_str());
    out.append(fmt4("\n    static final MemorySegment VT_{} = vt_{}();\n\n    private static MemorySegment vt_{}() {{\n        try {{\n            var l = MethodHandles.lookup();\n            MemorySegment vt = Arena.global().allocate({}L, 8);\n", copy tr, copy tr, copy tr, unum(@cast<u64>(fns.len) * 8 + 8)).as_str());
    out.append(fmt("{}            return vt;\n        } catch (ReflectiveOperationException e) {\n            throw new RuntimeException(e);\n        }\n    }\n", move table).as_str());
    out.append(fmt4("\n    // a {} for Volt: Volt's own as it is (given: no longer freed here), or a Java object behind an id\n    static MemorySegment {}_obj(Arena arena, {} v, boolean given) {{\n        MemorySegment o = arena.allocate(L_OBJ);\n        if (v instanceof volt_{} w) {{\n", copy tr, copy tr, copy tr, copy tr).as_str());
    out.append("            MemorySegment.copy(w.o, 0, o, 0, 24);\n            if (given) {\n                w.live[0] = false;\n            } else {\n                o.set(ADDRESS, 16, MemorySegment.NULL);\n            }\n            return o;\n        }\n        long id = NEXT.incrementAndGet();\n        OBJECTS.put(id, v);\n");
    out.append(fmt("        o.set(ADDRESS, 0, VT_{});\n        o.set(ADDRESS, 8, MemorySegment.ofAddress(id));\n        o.set(ADDRESS, 16, given ? DROP_OBJ : MemorySegment.NULL);\n        return o;\n    }\n", copy tr).as_str());
    out.append(fmt4("\n    /** trait {}'s value Volt made: close() frees it (or it's freed once unreachable) */\n    public static final class volt_{} implements {}, AutoCloseable {{\n        final MemorySegment o;\n        final boolean[] live;\n        private final Cleaner.Cleanable cleanable;\n\n        volt_{}(MemorySegment r) {{\n", this.c.ty_name(t), copy tr, copy tr, copy tr).as_str());
    out.append(fmt("            o = Arena.ofAuto().allocate(L_OBJ);\n            MemorySegment.copy(r, 0, o, 0, 24);\n            MemorySegment self = o.get(ADDRESS, 8);\n            MemorySegment drop = o.get(ADDRESS, 16);\n            boolean[] l = {true};\n            live = l;\n            cleanable = CLEANER.register(this, () -> {\n                if (l[0]) {\n                    l[0] = false;\n                    {}.drop(drop, self);\n                }\n            });\n        }\n", S(cls)).as_str());
    out.append(calls.as_str());
    out.append("\n        public void close() {\n            cleanable.clean();\n        }\n    }\n");
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
    out.append("// --enable-native-access=ALL-UNNAMED. Errors are thrown as VoltException, one subclass per error set.\nimport java.lang.foreign.*;\nimport java.lang.invoke.*;\nimport java.lang.ref.Cleaner;\nimport java.nio.charset.StandardCharsets;\nimport java.util.concurrent.ConcurrentHashMap;\nimport java.util.concurrent.atomic.AtomicLong;\nimport static java.lang.foreign.ValueLayout.*;\n\n");
    // restricted: the FFM calls (allowed with --enable-native-access); try: an arena a call doesn't use
    out.append(fmt2("@SuppressWarnings({{\"restricted\", \"try\"}})\npublic final class {} {{\n    private {}() {{}}\n\n", S(cls), S(cls)).as_str());
    out.append("    private static final Linker LINKER = Linker.nativeLinker();\n");
    out.append(fmt2("    private static final SymbolLookup LIB = SymbolLookup.libraryLookup(System.getProperty(\"volt.{}.lib\", System.mapLibraryName(\"{}\")), Arena.global());\n", S(cls), S(cls)).as_str());
    out.append("    private static final Cleaner CLEANER = Cleaner.create();\n");
    out.append("    static final StructLayout L_STR = MemoryLayout.structLayout(ADDRESS.withName(\"ptr\"), JAVA_LONG.withName(\"len\"));\n");
    out.append("    static final StructLayout L_SLICE = MemoryLayout.structLayout(ADDRESS.withName(\"ptr\"), JAVA_LONG.withName(\"len\"));\n");
    out.append("    static final StructLayout L_TEXT = MemoryLayout.structLayout(ADDRESS.withName(\"ptr\"), JAVA_LONG.withName(\"len\"), ADDRESS.withName(\"owner\"), ADDRESS.withName(\"drop\"));\n");
    out.append("    static final StructLayout L_LIST = MemoryLayout.structLayout(ADDRESS.withName(\"ptr\"), JAVA_LONG.withName(\"len\"), ADDRESS.withName(\"owner\"), ADDRESS.withName(\"drop\"));\n");
    out.append("    static final StructLayout L_OBJ = MemoryLayout.structLayout(ADDRESS.withName(\"vt\"), ADDRESS.withName(\"self\"), ADDRESS.withName(\"drop\"));\n");
    out.append("    private static final MethodHandle CALL_DROP = LINKER.downcallHandle(FunctionDescriptor.ofVoid(ADDRESS));\n");
    out.append("    // Java objects Volt holds (by id: lent for a call, or given until Volt drops them), and the\n    // memory of text given to Volt (freed when Volt drops it)\n    private static final ConcurrentHashMap<Long, Object> OBJECTS = new ConcurrentHashMap<>();\n    private static final ConcurrentHashMap<Long, Arena> GIVEN = new ConcurrentHashMap<>();\n    private static final AtomicLong NEXT = new AtomicLong();\n");
    out.append(fmt2("    private static final MemorySegment DROP_OBJ = up(\"dropObj\");\n    private static final MemorySegment DROP_TEXT = up(\"dropText\");\n\n    private static MemorySegment up(String name) {{\n        try {{\n            var h = MethodHandles.lookup().findStatic({}.class, name, MethodType.methodType(void.class, MemorySegment.class));\n            return LINKER.upcallStub(h, FunctionDescriptor.ofVoid(ADDRESS), Arena.global());\n        }} catch (ReflectiveOperationException e) {{\n            throw new RuntimeException(e);\n        }}\n    }}\n\n", S(cls), S("")).as_str());
    out.append("    // Volt drops a Java object it was given: forgotten, and closed when it's AutoCloseable\n    private static void dropObj(MemorySegment self) {\n        Object v = OBJECTS.remove(self.address());\n        if (v instanceof AutoCloseable c) {\n            try {\n                c.close();\n            } catch (Exception e) {\n                throw new RuntimeException(e);\n            }\n        }\n    }\n\n    private static void dropText(MemorySegment owner) {\n        Arena a = GIVEN.remove(owner.address());\n        if (a != null) {\n            a.close();\n        }\n    }\n\n    // a lent Java object, forgotten after the call\n    static void forget(MemorySegment o) {\n        OBJECTS.remove(o.get(ADDRESS, 8).address());\n    }\n\n    // what a trait fn's Java code threw while Volt called it: rethrown after the call\n    private static final ThreadLocal<Throwable> THROWN = new ThreadLocal<>();\n\n    static void thrown() {\n        Throwable t = THROWN.get();\n        if (t != null) {\n            THROWN.remove();\n            rethrow(t);\n        }\n    }\n\n    // a str a callback gives Volt: kept until the next one on this thread\n    // ponytail: Volt reads it before the callback runs again; hold more if a fn keeps two\n    private static final ThreadLocal<MemorySegment> KEPT = new ThreadLocal<>();\n\n    static MemorySegment keep(MemorySegment s) {\n        KEPT.set(s);\n        return s;\n    }\n\n    // owned text for Volt (a callback's or a trait fn's result): freed when Volt drops it\n    static MemorySegment give(String s) {\n        Arena a = Arena.ofShared();\n        long id = NEXT.incrementAndGet();\n        GIVEN.put(id, a);\n        byte[] b = s.getBytes(StandardCharsets.UTF_8);\n        MemorySegment bytes = a.allocate(Math.max(1, b.length));\n        MemorySegment.copy(b, 0, bytes, JAVA_BYTE, 0, b.length);\n        MemorySegment t = a.allocate(L_TEXT);\n        t.set(ADDRESS, 0, bytes);\n        t.set(JAVA_LONG, 8, b.length);\n        t.set(ADDRESS, 16, MemorySegment.ofAddress(id));\n        t.set(ADDRESS, 24, DROP_TEXT);\n        return t;\n    }\n\n    // calls what frees what Volt gave out (owner, through its drop)\n    static void drop(MemorySegment drop, MemorySegment owner) {\n        if (!drop.equals(MemorySegment.NULL)) {\n            try {\n                CALL_DROP.invokeExact(drop, owner);\n            } catch (Throwable e) {\n                throw new RuntimeException(e);\n            }\n        }\n    }\n\n");
    out.append("    // a String as a Volt str (UTF-8 in arena)\n    static MemorySegment str(Arena arena, String s) {\n        byte[] b = s.getBytes(StandardCharsets.UTF_8);\n        MemorySegment bytes = arena.allocate(Math.max(1, b.length));\n        MemorySegment.copy(b, 0, bytes, JAVA_BYTE, 0, b.length);\n        MemorySegment v = arena.allocate(L_STR);\n        v.set(ADDRESS, 0, bytes);\n        v.set(JAVA_LONG, 8, b.length);\n        return v;\n    }\n\n");
    out.append("    // a Volt str's text\n    static String text(MemorySegment v) {\n        long len = v.get(JAVA_LONG, 8);\n        byte[] b = v.get(ADDRESS, 0).reinterpret(len).toArray(JAVA_BYTE);\n        return new String(b, StandardCharsets.UTF_8);\n    }\n\n");
    out.append("    // owned text: copied out, then freed\n    static String take(MemorySegment t) {\n        String s = text(t);\n        MemorySegment drop = t.get(ADDRESS, 24);\n        if (!drop.equals(MemorySegment.NULL)) {\n            try {\n                CALL_DROP.invokeExact(drop, t.get(ADDRESS, 16));\n            } catch (Throwable e) {\n                throw new RuntimeException(e);\n            }\n        }\n        return s;\n    }\n\n");
    out.append("    static void rethrow(Throwable t) {\n        if (t instanceof RuntimeException e) {\n            throw e;\n        }\n        if (t instanceof Error e) {\n            throw e;\n        }\n        if (t != null) {\n            throw new RuntimeException(t);\n        }\n    }\n\n");
    out.append("    static MethodHandle find(String name, FunctionDescriptor d) {\n        return LINKER.downcallHandle(LIB.find(name).orElseThrow(() -> new UnsatisfiedLinkError(name)), d);\n    }\n");
    // errors
    out.append("\n    /** an error a Volt function returned: its code and name */\n    public static class VoltException extends RuntimeException {\n        private static final long serialVersionUID = 1L;\n        public final int code;\n        public final String name;\n\n        public VoltException(int code, String name) {\n            super(name);\n            this.code = code;\n            this.name = name;\n        }\n\n        /** the exception of an error code (a callback throws one to give Volt that error) */\n        public static VoltException of(int code) {\n            switch (code) {\n");
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
    // callbacks: an interface each, and the upcall that calls one (what it throws is kept, and
    // rethrown after the call)
    for (i) in 0..this.closures.len {
        val ct = *this.closures.at(i);
        var ps: std::vec<u32> = {};
        val r = this.fn_parts(ct, &ps);
        val ii = unum(@cast<u64>(i));
        var params: std::string = {};
        var cparams = S("MemorySegment user");
        var largs: std::string = {};
        for (k) in 0..ps.len {
            val p = *ps.at(k);
            val kk = unum(@cast<u64>(k));
            if (k > 0) {
                params.append(", ");
                largs.append(", ");
            }
            params.append(fmt2("{} a{}", this.java_ty(p, false), copy kk).as_str());
            cparams.append(fmt2(", {} a{}", this.java_carrier(this.in_ty(p)), copy kk).as_str());
            largs.append(this.java_from_c(p, fmt("a{}", copy kk).as_str()).as_str());
        }
        out.append(fmt3("\n    /** a callback: {} */\n    @FunctionalInterface\n    public interface Callback{} {{\n        {} call(", this.c.ty_name(ct), copy ii, this.java_ty(r, false)).as_str());
        out.append(fmt("{});\n    }\n", copy params).as_str());
        var target_ret = this.java_carrier(r);
        var mt = fmt("{}.class", this.java_carrier(r));
        if (r == VOID) {
            target_ret = S("void");
            mt = S("void.class");
        }
        mt.append(fmt(", Callback{}.class, Throwable[].class, MemorySegment.class", copy ii).as_str());
        var desc: std::string = {};
        this.java_up_types(&ps, r, &mt, &desc);
        out.append(fmt3("\n    private static {} call{}(Callback{} f, Throwable[] err, ", move target_ret, copy ii, copy ii).as_str());
        out.append(fmt("{}) {{\n        try {{\n", move cparams).as_str());
        out.append(indent(indent(indent(this.java_to_c(r, fmt("f.call({})", copy largs).as_str()).as_str()).as_str()).as_str()).as_str());
        out.append("        } catch (Throwable t) {\n            if (err[0] == null) {\n                err[0] = t;\n            }\n");
        if (r != VOID) {
            out.append(fmt("            return {};\n", this.java_zero(r)).as_str());
        }
        out.append("        }\n    }\n");
        out.append(fmt4("\n    private static MemorySegment upcall{}(Arena arena, Callback{} f, Throwable[] err) {{\n        try {{\n            MethodHandle h = MethodHandles.lookup().findStatic({}.class, \"call{}\", ", copy ii, copy ii, S(cls), copy ii).as_str());
        out.append(fmt2("MethodType.methodType({}));\n            h = MethodHandles.insertArguments(h, 0, f, err);\n            return LINKER.upcallStub(h, {}, arena);\n", move mt, copy desc).as_str());
        out.append("        } catch (ReflectiveOperationException e) {\n            throw new RuntimeException(e);\n        }\n    }\n");
        if (!has_u32(&this.closures_out, @cast<u32>(i))) {
            continue;
        }
        // one Volt gave out: called through its function, freed through its drop
        var args: std::vec<java_arg> = {};
        for (k) in 0..ps.len {
            var ja: java_arg = {};
            this.java_arg_of(*ps.at(k), fmt("a{}", unum(@cast<u64>(k))).as_str(), &ja);
            put(&args, move ja);
        }
        out.append(fmt4("\n    /** {}, given out by Volt: call(...) calls it; close() frees it (or it's freed once unreachable) */\n    public static final class Closure{} implements Callback{}, AutoCloseable {{\n        private static final FunctionDescriptor DESC = {};\n", this.c.ty_name(ct), copy ii, copy ii, move desc).as_str());
        out.append(fmt2("        private final MemorySegment self;\n        private final MethodHandle h;\n        private final Cleaner.Cleanable cleanable;\n\n        Closure{}(MemorySegment c) {\n            MemorySegment self = c.get(ADDRESS, 8);\n            MemorySegment drop = c.get(ADDRESS, 16);\n            this.self = self;\n            this.h = LINKER.downcallHandle(c.get(ADDRESS, 0), DESC);\n            this.cleanable = CLEANER.register(this, () -> {}.drop(drop, self));\n        }}\n\n", copy ii, S(cls)).as_str());
        out.append(fmt2("        public {} call({}) {{\n", this.java_ty(r, false), move params).as_str());
        out.append(indent(indent(indent(this.java_call(r, "h", &args, "self").as_str()).as_str()).as_str()).as_str());
        out.append("        }\n\n        public void close() {\n            cleanable.clean();\n        }\n    }\n");
    }
    for (k) in 0..this.traits.len {
        this.java_trait(@cast<u32>(k), &out);
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
    // lists that come back: their elements copied out (each handle the caller's), then freed
    for (k) in 0..this.lists.len {
        val e = this.list_elem(*this.lists.at(k));
        var v = this.view_of(e);
        if (this.handle_of(e) != null) {
            v = e;
        }
        val et = this.java_ty(this.view_of(e), false);
        val z = this.csize(this.view_of(e)).size;
        out.append(fmt3("\n    static {}[] list_{}(MemorySegment v) {{\n        long n = v.get(JAVA_LONG, 8);\n        MemorySegment e = v.get(ADDRESS, 0).reinterpret(n * {}L);\n", copy et, unum(@cast<u64>(k)), unum(z)).as_str());
        out.append(fmt3("        {}[] out = new {}[(int) n];\n        for (int i = 0; i < n; i++) {{\n            out[i] = {};\n        }}\n", copy et, copy et, this.java_read(v, fmt("e.asSlice(i * {}L)", unum(z)).as_str(), 0)).as_str());
        out.append("        drop(v.get(ADDRESS, 24), v.get(ADDRESS, 16));\n        return out;\n    }\n");
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
        out.append(fmt4("\n    /** export struct {}: close() (or try-with-resources) frees it; otherwise it's freed once unreachable */\n    public static final class {} implements AutoCloseable {{\n        private final MemorySegment h;\n        private final boolean[] live;\n        private final Cleaner.Cleanable cleanable;\n\n        {}(MemorySegment h) {{\n            this(h, true);\n        }}\n\n", S(this.c.si(*s).name), copy n, copy n, S("")).as_str());
        out.append(fmt("        // own: freed here (one Volt lends never is)\n        {}(MemorySegment h, boolean own) {\n            this.h = h;\n            boolean[] l = {own};\n            this.live = l;\n", copy n).as_str());
        out.append(fmt("            this.cleanable = CLEANER.register(this, () -> {\n                if (l[0]) {\n                    l[0] = false;\n                    free(h);\n                }\n            });\n        }\n\n        private static void free(MemorySegment h) {\n            try {\n                H_{}.invokeExact(h);\n            } catch (Throwable e) {\n                throw new RuntimeException(e);\n            }\n        }\n\n", this.free_name(*s)).as_str());
        out.append("        public void close() {\n            cleanable.clean();\n        }\n\n        MemorySegment handle() {\n            return h;\n        }\n\n        // gives the handle up (to Volt, which frees it)\n        MemorySegment release() {\n            live[0] = false;\n            return h;\n        }\n");
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
        .LIST(x) => { return fmt("[]{}", this.go_ty(this.list_elem(t))); },
        .OPT(x) => {
            // an optional handle is the type's pointer (nil: none)
            match (this.shape_of(x) ?? shape::VOID) {
                .HANDLE(h) => { return this.go_ty(x); },
                default => {},
            }
            return fmt("*{}", this.go_ty(x));
        },
        .RESULT(e, x) => { return this.go_ty(x); },
        .TRAIT(i) => { return go_name(this.short(this.trait_of(t)).as_str()); },
        .CLOSURE(i) => {
            var ps: std::vec<u32> = {};
            val r = this.fn_parts(t, &ps);
            return fmt2("func({}){}", this.go_tys(&ps), this.go_results(r));
        },
        default => { return S("unsafe.Pointer"); },
    }
}

// "A, B": the Go types of ps
attach fn go_tys(this: bind&, ps: std::vec<u32>&) -> std::string {
    var s: std::string = {};
    for (k) in 0..ps.len {
        if (k > 0) {
            s.append(", ");
        }
        s.append(this.go_ty(*ps.at(k)).as_str());
    }
    return s;
}

// the C type cgo calls it (C.int32_t, C.mathlib_vec2, *C.mathlib_counter...)
attach fn go_cty(this: bind&, t: u32) -> std::string {
    val h = this.handle_of(t);
    if (h) {
        return fmt("*C.{}", this.c_named(this.c.si(h).name, false));
    }
    match (this.shape_of(t) ?? shape::VOID) {
        .VOID => { return {}; },
        .CSTR => { return S("*C.char"); },
        .PTR(x) => {
            if (x == VOID) {
                return S("unsafe.Pointer");
            }
            return fmt("*{}", this.go_cty(x));
        },
        .OPT(x) => {
            if (this.handle_of(x) != null) {
                return this.go_cty(x);
            }
        },
        .ARRAY(e, n) => { return S("unsafe.Pointer"); },
        .FN(i) => { return S("unsafe.Pointer"); },
        default => {},
    }
    return fmt("C.{}", this.c_out(t, false));
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

// the Go expression converting Go value v (of plain type t, or a str lent for the call) to C
attach fn go_to_c(this: bind&, t: u32, v: str) -> std::string {
    match (this.shape_of(t) ?? shape::VOID) {
        .STRUCT(s) => { return fmt("{}.c()", S(v)); },
        .STR => { return fmt("goStr({})", S(v)); },
        default => { return fmt2("{}({})", this.go_cty(t), S(v)); },
    }
}

// the Go expression converting C value v (of plain type t, or what Volt passes a Go function) to
// Go: text as a string (a copy), a handle Volt lends as one that never frees it, one it gives as
// the caller's
attach fn go_from_c(this: bind&, t: u32, v: str) -> std::string {
    val h = this.lent_handle(t);
    if (h) {
        return fmt2("&{}{{h: {}, lent: true}}", this.go_tname(this.c.si(h).name), S(v));
    }
    match (this.shape_of(t) ?? shape::VOID) {
        .STRUCT(s) => { return fmt2("{}FromC({})", this.go_tname(this.c.si(s).name), S(v)); },
        .BOOL => { return fmt("bool({})", S(v)); },
        .STR => { return fmt("goString({})", S(v)); },
        .TEXT(x) => { return fmt("goString({})", S(v)); },
        .CSTR => { return fmt("C.GoString({})", S(v)); },
        .HANDLE(s) => { return fmt2("wrap{}({})", this.go_tname(this.c.si(s).name), S(v)); },
        .PTR(x) => { return fmt("unsafe.Pointer({})", S(v)); },
        default => { return fmt2("{}({})", this.go_ty(t), S(v)); },
    }
}

// the C form of Go value v (of type t) a Go function gives Volt back (s is its callback): text
// copied into C memory Volt frees, a str into C memory freed when the call s was passed to
// returns, a handle given up
attach fn go_give(this: bind&, t: u32, v: str) -> std::string {
    if (this.lent_handle(t) != null) {
        return fmt("{}.handle()", S(v));
    }
    match (this.shape_of(t) ?? shape::VOID) {
        .TEXT(x) => { return fmt("goText({})", S(v)); },
        .STR => { return fmt("s.str({})", S(v)); },
        .CSTR => { return fmt("(*C.char)(unsafe.Pointer(s.str({} + \"\\x00\").ptr))", S(v)); },
        .HANDLE(h) => { return fmt("{}.give()", S(v)); },
        .PTR(x) => { return fmt2("({})({})", this.go_cty(t), S(v)); },
        default => { return this.go_to_c(t, v); },
    }
}

// the statements of a Go function Volt calls that give back the C form of r, call's result (E!T
// comes from Go as (T, error), E!void as error)
attach fn go_return(this: bind&, r: u32, call: str) -> std::string {
    match (this.shape_of(r) ?? shape::VOID) {
        .VOID => { return fmt("{}\n", S(call)); },
        .RESULT(e, x) => {
            val rn = this.c_named(this.result_name(r).as_str(), false);
            if (x == VOID) {
                return fmt2("return C.{}{{error: codeOf({})}}\n", copy rn, S(call));
            }
            var out = fmt2("v, err := {}\nif err != nil {{\n    return C.{}{{error: codeOf(err)}}\n}}\n", S(call), copy rn);
            out.append(fmt2("return C.{}{{value: {}}}\n", copy rn, this.go_give(x, "v")).as_str());
            return out;
        },
        default => { return fmt("return {}\n", this.go_give(r, call)); },
    }
}

// a Go function Volt calls with the handle of a callback (first) and ps' C forms: it calls target
// with Go values and gives back r's C form. A panic is kept in the callback (re-panicked when the
// call it was passed to returns): Volt gets r's zero (empty text), or, when r is a handle, which
// has none, the program ends
attach fn go_export(this: bind&, name: str, first: str, target: str, ps: std::vec<u32>&, r: u32) -> std::string {
    var params = fmt("{} unsafe.Pointer", S(first));
    var args: std::string = {};
    // a handle Volt lends is good for this call only: its value is cleared when it returns
    var lent: std::string = {};
    for (k) in 0..ps.len {
        val a = fmt("a{}", unum(@cast<u64>(k)));
        params.append(fmt2(", {} {}", copy a, this.go_cty(this.in_ty(*ps.at(k)))).as_str());
        if (k > 0) {
            args.append(", ");
        }
        if (this.lent_handle(*ps.at(k)) != null) {
            lent.append(fmt3("    {}_l := {}\n    defer func() {{ {}_l.h = nil }}()\n", copy a, this.go_from_c(*ps.at(k), a.as_str()), copy a).as_str());
            args.append(fmt("{}_l", copy a).as_str());
            continue;
        }
        args.append(this.go_from_c(*ps.at(k), a.as_str()).as_str());
    }
    var ret: std::string = {};
    if (r != VOID) {
        ret = fmt(" (out {})", this.go_cty(r));
    }
    var caught = S("            s.catch(v)\n");
    if (this.handle_of(r) != null || this.is_ref(r)) {
        caught = S("            fatal(v)\n");
    }
    match (this.shape_of(r) ?? shape::VOID) {
        .TEXT(x) => { caught.append("            out = goText(\"\")\n"); },
        default => {},
    }
    var out = fmt4("\n//export {}\nfunc {}({}){} {{\n", S(name), S(name), move params, move ret);
    out.append(fmt2("    s := (*cgo.Handle)({}).Value().(*callback)\n    defer func() {{\n        if v := recover(); v != nil {{\n{}        }}\n    }}()\n", S(first), move caught).as_str());
    out.append(lent.as_str());
    out.append(indent(this.go_return(r, fmt2("{}({})", S(target), move args).as_str()).as_str()).as_str());
    out.append("}\n");
    return out;
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
    give: std::string = {}; // after every argument's before: letting go of what's given to Volt
    after: std::string = {};
    // first: what has to stay alive until the wrapper returns (the result may borrow from it, and
    // a finalizer would free it once the last use is the call)
    keep: std::string = {};
}

attach fn go_arg_of(this: bind&, t: u32, name: str, a: go_arg&) -> void {
    val n = S(name);
    a.decl = fmt2("{} {}", copy n, this.go_ty(t));
    if (this.lent_handle(t) != null) {
        a.pass = fmt("{}.handle()", copy n);
        a.keep = fmt("defer runtime.KeepAlive({})\n", copy n);
        return;
    }
    if (this.go_plain(t)) {
        a.pass = this.go_to_c(t, name);
        return;
    }
    match (this.shape_of(t) ?? shape::VOID) {
        .STR => {
            a.pass = fmt("goStr({})", copy n);
            a.keep = fmt("defer runtime.KeepAlive({})\n", copy n);
        },
        .TEXT(x) => {
            // owned text in: Volt copies it
            a.pass = fmt("goStr({})", copy n);
            a.keep = fmt("defer runtime.KeepAlive({})\n", copy n);
        },
        .CSTR => {
            a.before = fmt2("{}_c := C.CString({})\ndefer C.free(unsafe.Pointer(", copy n, copy n);
            a.before.append(fmt("{}_c))\n", copy n).as_str());
            a.pass = fmt("{}_c", copy n);
        },
        .PTR(x) => {
            if (x != VOID) {
                match (this.shape_of(x) ?? shape::VOID) {
                    .STRUCT(s) => {
                        // a copy goes in, and what Volt changed comes back
                        val cn = this.c_named(this.c.si(s).name, false);
                        a.before = fmt3("var {}_c *C.{}\nif {} != nil {{\n", copy n, copy cn, copy n);
                        a.before.append(fmt2("    v := {}.c()\n    {}_c = &v\n}}\n", copy n, copy n).as_str());
                        a.pass = fmt("{}_c", copy n);
                        a.after = fmt3("if {} != nil {{\n    *{} = {}FromC(*", copy n, copy n, this.go_tname(this.c.si(s).name));
                        a.after.append(fmt("{}_c)\n}\n", copy n).as_str());
                        return;
                    },
                    default => {},
                }
            }
            a.decl = fmt("{} unsafe.Pointer", copy n);
            a.pass = copy n;
        },
        .HANDLE(s) => {
            // given to Volt, which frees it (let go once every argument is checked)
            a.before = fmt2("{}_h := {}.owned()\n", copy n, copy n);
            a.give = fmt("{}.forget()\n", copy n);
            a.pass = fmt("{}_h", copy n);
        },
        .TRAIT(i) => {
            // lent for the call, or given (see ofT)
            var given = S("true");
            if (this.is_ref(t)) {
                given = S("false");
            }
            a.before = fmt5("{}_o, {}_done := of{}({}, {})\n", copy n, copy n, go_name(this.short(this.trait_of(t)).as_str()), copy n, move given);
            a.before.append(fmt("defer {}_done()\n", copy n).as_str());
            a.pass = fmt("{}_o", copy n);
        },
        .SLICE(x) => { this.go_slice_arg(x, false, name, a); },
        .LIST(x) => {
            // given to Volt, which copies the elements (and takes the handles)
            this.go_slice_arg(this.view_of(this.list_elem(t)), true, name, a);
        },
        .OPT(x) => {
            if (this.handle_of(x) != null) {
                // given to Volt, which frees it (nil: none)
                a.before = fmt4("var {}_c {}\nif {} != nil {{\n    {}_c = ", copy n, this.go_cty(x), copy n, copy n);
                a.before.append(fmt("{}.owned()\n}\n", copy n).as_str());
                a.give = fmt2("if {} != nil {{\n    {}.forget()\n}}\n", copy n, copy n);
                a.pass = fmt("{}_c", copy n);
                return;
            }
            // text as a str, which Volt copies
            val v = this.in_ty(x);
            a.before = fmt3("var {}_c C.{}\nif {} != nil {{\n", copy n, this.made_name("opt", v, false), copy n);
            a.before.append(fmt3("    {}_c.value = {}\n    {}_c.has = true\n}}\n", copy n, this.go_to_c(v, fmt("*{}", copy n).as_str()), copy n).as_str());
            a.pass = fmt("{}_c", copy n);
            a.keep = fmt("defer runtime.KeepAlive({})\n", copy n);
        },
        .CLOSURE(i) => {
            // the C side calls back through an exported Go function, which finds f by its handle
            a.before = fmt3("{}_s := &callback{{f: {}}}\n{}_h := cgo.NewHandle(", copy n, copy n, copy n);
            a.before.append(fmt3("{}_s)\ndefer {}_h.Delete()\ndefer {}_s.done()\n", copy n, copy n, copy n).as_str());
            // a pointer to the handle (cgo's rule: C may use it during the call, and it holds no Go pointers)
            a.pass = fmt3("C.{}(C.{}cb{}), unsafe.Pointer(&", this.cb_name(i, false), S(this.pkg), unum(@cast<u64>(i)));
            a.pass.append(fmt("{}_h)", copy n).as_str());
        },
        default => { a.pass = copy n; },
    }
}

// a slice parameter whose elements C takes as x (text as str, a handle as its pointer); given: a
// list's, whose handles are given up
attach fn go_slice_arg(this: bind&, x: u32, given: bool, name: str, a: go_arg&) -> void {
    val n = S(name);
    val sn = this.made_name("slice", x, false);
    if (x == STR) {
        // the strings' bytes, pinned for the call (see goStrs)
        a.before = fmt2("var {}_pin runtime.Pinner\ndefer {}_pin.Unpin()\n", copy n, copy n);
        a.pass = fmt2("goStrs({}, &{}_pin)", copy n, copy n);
        a.keep = fmt("defer runtime.KeepAlive({})\n", copy n);
        return;
    }
    // what C reads: the elements in place, or a copy
    var pass = fmt3("C.{}{{ptr: &{}_c[0], len: C.size_t(len({}))}}", copy sn, copy n, copy n);
    if (this.handle_of(x) != null) {
        // the handles' pointers, each checked before any is given up
        var get = S("handle");
        if (given) {
            get = S("owned");
        }
        a.before = fmt4("{}_c := make([]{}, len({})+1)\nfor i, x := range {} {{\n", copy n, this.go_cty(x), copy n, copy n);
        a.before.append(fmt2("    {}_c[i] = x.{}()\n}}\n", copy n, move get).as_str());
        a.pass = move pass;
        if (given) {
            a.give = fmt("for _, x := range {} {{\n    x.forget()\n}}\n", copy n);
        } else {
            a.keep = fmt("defer runtime.KeepAlive({})\n", copy n);
        }
        return;
    }
    if (this.go_same_layout(x)) {
        // the Go elements are the C elements: passed in place
        a.before = fmt4("var {}_p *{}\nif len({}) > 0 {{\n    {}_p = ", copy n, this.go_cty(x), copy n, copy n);
        a.before.append(fmt2("(*{})(unsafe.Pointer(&{}[0]))\n}}\n", this.go_cty(x), copy n).as_str());
        a.pass = fmt3("C.{}{{ptr: {}_p, len: C.size_t(len({}))}}", copy sn, copy n, copy n);
        a.keep = fmt("defer runtime.KeepAlive({})\n", copy n);
        return;
    }
    a.pass = move pass;
    match (this.shape_of(x) ?? shape::VOID) {
        .OPT(v) => {
            // optionals: a C copy (what Volt writes in it doesn't come back)
            val on = this.made_name("opt", v, false);
            a.before = fmt4("{}_c := make([]C.{}, len({})+1)\nfor i, v := range {} {{\n", copy n, copy on, copy n, copy n);
            a.before.append(fmt3("    if v != nil {{\n        {}_c[i] = C.{}{{value: {}, has: true}}\n    }}\n}}\n", copy n, copy on, this.go_to_c(v, "*v")).as_str());
            return;
        },
        default => {},
    }
    // structs: a C copy, and what Volt wrote comes back
    a.before = fmt4("{}_c := make([]{}, len({})+1)\nfor i, v := range {} {{\n", copy n, this.go_cty(x), copy n, copy n);
    a.before.append(fmt2("    {}_c[i] = {}\n}}\n", copy n, this.go_to_c(x, "v")).as_str());
    a.after = fmt2("for i := range {} {{\n    {}[i] = ", copy n, copy n);
    a.after.append(fmt("{}\n}\n", this.go_from_c(x, fmt("{}_c[i]", copy n).as_str())).as_str());
}

// what a wrapper returns: Go result types, and whether it adds an error or a found flag (an
// optional handle is nil for none)
attach fn go_results(this: bind&, t: u32) -> std::string {
    match (this.shape_of(t) ?? shape::VOID) {
        .VOID => { return {}; },
        .RESULT(e, x) => {
            if (x == VOID) {
                return S(" error");
            }
            return fmt(" ({}, error)", this.go_ret(x));
        },
        .OPT(x) => {
            if (this.handle_of(x) != null) {
                return fmt(" {}", this.go_ty(x));
            }
            return fmt(" ({}, bool)", this.go_ty(x));
        },
        default => { return fmt(" {}", this.go_ret(t)); },
    }
}

// the Go type of a value Volt gives back: a trait's as VoltT, a closure as ClosureN
attach fn go_ret(this: bind&, t: u32) -> std::string {
    match (this.shape_of(t) ?? shape::VOID) {
        .TRAIT(i) => { return fmt("*Volt{}", go_name(this.short(this.trait_of(t)).as_str())); },
        .CLOSURE(i) => { return fmt("*Closure{}", unum(@cast<u64>(i))); },
        default => { return this.go_ty(t); },
    }
}

// the Go value of C result r (of type t)
attach fn go_value(this: bind&, t: u32, r: str) -> std::string {
    if (this.go_plain(t) || this.lent_handle(t) != null) {
        return this.go_from_c(t, r);
    }
    match (this.shape_of(t) ?? shape::VOID) {
        .STR => { return fmt("goString({})", S(r)); },
        .CSTR => { return fmt("C.GoString({})", S(r)); },
        .TEXT(x) => { return fmt("takeText({})", S(r)); },
        .HANDLE(s) => { return fmt2("wrap{}({})", this.go_tname(this.c.si(s).name), S(r)); },
        .TRAIT(i) => { return fmt2("wrapVolt{}({})", go_name(this.short(this.trait_of(t)).as_str()), S(r)); },
        .CLOSURE(i) => { return fmt2("wrapClosure{}({})", unum(@cast<u64>(i)), S(r)); },
        .LIST(x) => {
            // copied into a slice (text copied, each handle the slice's), and the list freed
            val e = this.list_elem(t);
            var f = fmt3("func(x {}) {} {{ return {} }}", this.go_cty(this.view_of(e)), this.go_ty(e), this.go_value(e, "x"));
            match (this.shape_of(e) ?? shape::VOID) {
                .TEXT(y) => { f = S("goString"); },
                .HANDLE(h) => { f = fmt("wrap{}", this.go_tname(this.c.si(h).name)); },
                default => {},
            }
            return fmt5("takeList({}.ptr, {}.len, {}.owner, {}.drop, {})", S(r), S(r), S(r), S(r), move f);
        },
        .SLICE(x) => {
            if (this.go_same_layout(x)) {
                return fmt4("append([]{}(nil), unsafe.Slice((*{})(unsafe.Pointer({}.ptr)), int({}.len))...)", this.go_ty(x), this.go_ty(x), S(r), S(r));
            }
            return fmt("nil /* {} */", this.c.ty_name(t));
        },
        default => { return S(r); },
    }
}

// the statements of a Go wrapper calling call (a C function) with self_pass first (a method's
// receiver, o) and args, returning t's Go value
attach fn go_call(this: bind&, call: std::string, self_pass: str?, args: std::vec<go_arg>&, t: u32) -> std::string {
    var passes: std::string = {};
    var before: std::string = {};
    var give: std::string = {};
    var after: std::string = {};
    val sp = self_pass;
    if (sp) {
        passes.append(sp);
        before.append("defer runtime.KeepAlive(o)\n");
    }
    for (a&) in args.items() {
        before.append(a.keep.as_str());
    }
    for (a&) in args.items() {
        if (passes.len() > 0) {
            passes.append(", ");
        }
        passes.append(a.pass.as_str());
        before.append(a.before.as_str());
        give.append(a.give.as_str());
        after.append(a.after.as_str());
    }
    var out = move before;
    out.append(give.as_str());
    val c = fmt2("{}({})", move call, move passes);
    if (t == VOID) {
        out.append(fmt("{}\n", move c).as_str());
        out.append(after.as_str());
        return out;
    }
    out.append(fmt("r := {}\n", move c).as_str());
    out.append(after.as_str());
    match (this.shape_of(t) ?? shape::VOID) {
        .RESULT(e, x) => {
            if (x == VOID) {
                out.append("if r.error != 0 {\n    return errorOf(uint32(r.error))\n}\nreturn nil\n");
            } else {
                out.append(fmt("if r.error != 0 {\n    var zero {}\n    return zero, errorOf(uint32(r.error))\n}\n", this.go_ret(x)).as_str());
                out.append(fmt("return {}, nil\n", this.go_value(x, "r.value")).as_str());
            }
        },
        .OPT(x) => {
            if (this.handle_of(x) != null) {
                // nil for none
                out.append(fmt("return {}\n", this.go_value(x, "r")).as_str());
                return out;
            }
            out.append(fmt("if !r.has {\n    var zero {}\n    return zero, false\n}\n", this.go_ty(x)).as_str());
            out.append(fmt("return {}, true\n", this.go_value(x, "r.value")).as_str());
        },
        default => { out.append(fmt("return {}\n", this.go_value(t, "r")).as_str()); },
    }
    return out;
}

attach fn go_body(this: bind&, f: u32, args: std::vec<go_arg>&, self_pass: str?) -> std::string {
    val info = this.c.fi(f);
    return this.go_call(fmt("C.{}", S(info.c_name)), self_pass, args, info.ret);
}

fn go_keyword(s: str) -> bool {
    val words: str[] = { "break", "case", "chan", "const", "continue", "default", "defer", "else", "fallthrough", "for", "func", "go", "goto", "if", "import", "interface", "map", "package", "range", "return", "select", "struct", "switch", "type", "var", "len", "cap", "new", "make", "error", "string", "r", "o", "C", "runtime", "unsafe", "cgo" };
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

// s, then spaces up to n bytes (gofmt's columns)
fn pad_to(s: str, n: usize) -> std::string {
    var out = S(s);
    while (out.len() < n) {
        out.push(' ');
    }
    return out;
}

// what Go calls through C function pointers (it can't call one itself), and the tables of Go values
// of traits: static inline C, so each copy of the preamble (cgo makes two) has its own, and they
// may sit next to //export
attach fn go_c_helpers(this: bind&) -> std::string {
    val p = S(this.pkg);
    var out: std::string = {};
    if (this.lists.len > 0 || this.closures_out.len > 0 || this.traits.len > 0) {
        out.append(fmt("static inline void {}_go_drop(void (*drop)(void *), void *self) {{\n    if (drop) {{\n        drop(self);\n    }}\n}}\n", copy p).as_str());
    }
    if (this.texts.len > 0) {
        // text Go gives Volt: bytes in C memory, freed with free
        out.append(fmt("static inline void {}_go_free(void *p) {{\n    free(p);\n}}\n", copy p).as_str());
        out.append(fmt2("static inline volt_text {}_go_text(void *p, size_t n) {{\n    volt_text t = {{(const uint8_t *)p, n, p, {}_go_free}};\n    return t;\n}}\n", copy p, copy p).as_str());
    }
    for (i) in 0..this.closures.len {
        if (!has_u32(&this.closures_out, @cast<u32>(i))) {
            continue;
        }
        val ct = *this.closures.at(i);
        var ps: std::vec<u32> = {};
        val r = this.fn_parts(ct, &ps);
        out.append(this.go_c_call(fmt2("{}_go_closure{}", copy p, unum(@cast<u64>(i))).as_str(), fmt("{} c", this.c_out(ct, false)).as_str(), "c.call(c.self", &ps, r).as_str());
    }
    if (this.traits.len > 0) {
        out.append(fmt("extern void {}GoDrop(void *self);\n", copy p).as_str());
    }
    for (t&) in this.traits.items() {
        val sh = this.short(*t);
        val tn = go_name(sh.as_str());
        var vt = copy sh;
        vt.append("_vt");
        val vtn = this.c_named(vt.as_str(), false);
        val fns = this.fns_of(*t);
        var names: std::string = {};
        for (f&) in fns.items() {
            var params = S("void *self");
            for (k) in 0..f.params.len {
                params.append(fmt2(", {}a{}", spaced(this.c_in(*f.params.at(k), false)), unum(@cast<u64>(k))).as_str());
            }
            val gn = fmt3("{}{}{}", copy p, copy tn, go_name(f.name));
            out.append(fmt3("extern {}{}({});\n", spaced(this.c_out(f.ret, false)), copy gn, move params).as_str());
            if (names.len() > 0) {
                names.append(", ");
            }
            names.append(gn.as_str());
        }
        out.append(fmt5("static inline const {} *{}_go_{}_vt(void) {{\n    static const {} vt = {{{}}};\n    return &vt;\n}}\n", copy vtn, copy p, copy sh, copy vtn, move names).as_str());
        for (f&) in fns.items() {
            out.append(this.go_c_call(fmt3("{}_go_{}_{}", copy p, copy sh, S(f.name)).as_str(), fmt("{} o", this.c_named(sh.as_str(), false)).as_str(), fmt("o.vt->{}(o.self", S(f.name)).as_str(), &f.params, f.ret).as_str());
        }
    }
    if (out.len() == 0) {
        return out;
    }
    return fmt("// what Go calls through C function pointers, and the tables of Go values of traits (static\n// inline: each copy of this preamble has its own, so they may sit next to //export)\n{}", move out);
}

// a static inline C function name(first, a0..) calling a function pointer: call (up to its first
// argument), a0..)
attach fn go_c_call(this: bind&, name: str, first: str, call: str, ps: std::vec<u32>&, r: u32) -> std::string {
    var params = S(first);
    var args = S(call);
    for (k) in 0..ps.len {
        val a = fmt("a{}", unum(@cast<u64>(k)));
        params.append(fmt2(", {}{}", spaced(this.c_in(*ps.at(k), false)), copy a).as_str());
        args.append(fmt(", {}", copy a).as_str());
    }
    var ret = S("return ");
    if (r == VOID) {
        ret = {};
    }
    return fmt5("static inline {}{}({}) {{\n    {}{});\n}}\n", spaced(this.c_out(r, false)), S(name), move params, move ret, move args);
}

// a Go method of a value Volt gave out (o): its C call (a helper above), with ps as a0..
attach fn go_method(this: bind&, recv: str, name: str, call: std::string, ps: std::vec<u32>&, r: u32) -> std::string {
    var args: std::vec<go_arg> = {};
    for (k) in 0..ps.len {
        var a: go_arg = {};
        this.go_arg_of(*ps.at(k), fmt("a{}", unum(@cast<u64>(k))).as_str(), &a);
        put(&args, move a);
    }
    var out = fmt4("\nfunc (o *{}) {}({}){} {{\n", S(recv), S(name), go_decls(&args), this.go_results(r));
    out.append(indent(this.go_call(move call, "o.live()", &args, r).as_str()).as_str());
    out.append("}\n");
    return out;
}

// closure type K given out by Volt: a type with Call and Close
attach fn go_closure(this: bind&, k: u32, out: std::string&) -> void {
    val ct = *this.closures.at(k);
    var ps: std::vec<u32> = {};
    val r = this.fn_parts(ct, &ps);
    val n = fmt("Closure{}", unum(@cast<u64>(k)));
    var tpl = S("\n// $N is $T, given out by Volt: Call calls it; Close frees it (or the garbage collector does).\ntype $N struct {\n    c C.$C\n}\n\nfunc wrap$N(c C.$C) *$N {\n    o := &$N{c: c}\n    runtime.SetFinalizer(o, (*$N).Close)\n    return o\n}\n");
    tpl.append("\n// Close frees the closure (once; later calls do nothing).\nfunc (o *$N) Close() {\n    if o.c.call != nil {\n        C.$P_go_drop(o.c.drop, o.c.self)\n        o.c = C.$C{}\n        runtime.SetFinalizer(o, nil)\n    }\n}\n");
    tpl.append("\nfunc (o *$N) live() C.$C {\n    if o.c.call == nil {\n        panic(\"$N: used after Close\")\n    }\n    return o.c\n}\n");
    tpl = replace_all(tpl.as_str(), "$N", n.as_str());
    tpl = replace_all(tpl.as_str(), "$T", this.c.ty_name(ct).as_str());
    tpl = replace_all(tpl.as_str(), "$C", this.c_out(ct, false).as_str());
    out.append(replace_all(tpl.as_str(), "$P", this.pkg).as_str());
    out.append("\n// Call calls the closure.");
    out.append(this.go_method(n.as_str(), "Call", fmt2("C.{}_go_closure{}", S(this.pkg), unum(@cast<u64>(k))), &ps, r).as_str());
}

// trait K in Go: an interface (any Go value with its methods passes where Volt takes one, through
// a table of exported Go functions), VoltT for one Volt gave out, and ofT, which makes a Go value
// Volt's object
attach fn go_trait(this: bind&, k: u32, out: std::string&) -> void {
    val t = *this.traits.at(k);
    val sh = this.short(t);
    val tn = go_name(sh.as_str());
    val fns = this.fns_of(t);
    out.append(fmt3("\n// {} is Volt trait {}: any Go value with its methods passes where Volt takes one (lent for the call, or given: Volt calls its Close, if it has one, when it's done with it). One Volt gives back is a *Volt{}.\ntype ", copy tn, this.c.ty_name(t), copy tn).as_str());
    out.append(fmt("{} interface {{\n", copy tn).as_str());
    for (f&) in fns.items() {
        out.append(fmt3("    {}({}){}\n", go_name(f.name), this.go_tys(&f.params), this.go_results(f.ret)).as_str());
    }
    out.append("}\n");
    // the table's functions, which call the Go value's methods
    for (f&) in fns.items() {
        out.append(this.go_export(fmt3("{}{}{}", S(this.pkg), copy tn, go_name(f.name)).as_str(), "self", fmt2("s.f.({}).{}", copy tn, go_name(f.name)).as_str(), &f.params, f.ret).as_str());
    }
    var tpl = S("\n// Volt$T is a $T Volt gave out: its methods call Volt's; Close frees it (or the garbage collector does).\ntype Volt$T struct {\n    o C.$O\n}\n\nfunc wrapVolt$T(o C.$O) *Volt$T {\n    w := &Volt$T{o: o}\n    runtime.SetFinalizer(w, (*Volt$T).Close)\n    return w\n}\n");
    tpl.append("\n// Close frees it (once; later calls do nothing).\nfunc (w *Volt$T) Close() {\n    if w.o.vt != nil {\n        C.$P_go_drop(w.o.drop, w.o.self)\n        w.o = C.$O{}\n        runtime.SetFinalizer(w, nil)\n    }\n}\n");
    tpl.append("\nfunc (w *Volt$T) live() C.$O {\n    if w.o.vt == nil {\n        panic(\"Volt$T: used after Close\")\n    }\n    return w.o\n}\n");
    var methods: std::string = {};
    for (f&) in fns.items() {
        methods.append(this.go_method(fmt("Volt{}", copy tn).as_str(), go_name(f.name).as_str(), fmt3("C.{}_go_{}_{}", S(this.pkg), copy sh, S(f.name)), &f.params, f.ret).as_str());
    }
    tpl.append(methods.as_str());
    tpl.append("\n// of$T is v as Volt's $T for a call: a *Volt$T as it is (given: Volt's from here), any other value through a table calling its methods (lent for the call, or given: Volt drops it). done ends the call: it lets go of what only the call needed, and re-panics what v's methods panicked with.\n");
    tpl.append("func of$T(v $T, given bool) (o C.$O, done func()) {\n    if v == nil {\n        panic(\"$P: a nil $T\")\n    }\n    if w, ok := v.(*Volt$T); ok {\n        o = w.live()\n        if given {\n            w.o = C.$O{}\n            runtime.SetFinalizer(w, nil)\n        } else {\n            o.drop = nil\n        }\n        return o, func() { runtime.KeepAlive(w) }\n    }\n");
    tpl.append("    s := &callback{f: v}\n    h := (*cgo.Handle)(C.malloc(C.size_t(unsafe.Sizeof(cgo.Handle(0)))))\n    *h = cgo.NewHandle(s)\n    o = C.$O{vt: C.$P_go_$S_vt(), self: unsafe.Pointer(h)}\n    if given {\n        o.drop = (*[0]byte)(C.$PGoDrop)\n        return o, s.done\n    }\n    return o, func() {\n        h.Delete()\n        C.free(unsafe.Pointer(h))\n        s.done()\n    }\n}\n");
    tpl = replace_all(tpl.as_str(), "$T", tn.as_str());
    tpl = replace_all(tpl.as_str(), "$O", this.c_named(sh.as_str(), false).as_str());
    tpl = replace_all(tpl.as_str(), "$S", sh.as_str());
    out.append(replace_all(tpl.as_str(), "$P", this.pkg).as_str());
}

// the Go part (after import "C") indented with tabs, as gofmt does
fn go_tabs(s: str) -> std::string {
    var out: std::string = {};
    var start = true;
    var i: usize = 0;
    while (i < s.len) {
        if (start && i + 4 <= s.len && s[i..i + 4] == "    ") {
            out.push('\t');
            i += 4;
            continue;
        }
        start = s[i] == '\n';
        out.push(s[i]);
        i += 1;
    }
    return out;
}

attach fn go_text(this: bind&) -> std::string {
    val ents = this.entries();
    val p = this.pkg;
    // Go functions Volt calls back (closures as parameters, the methods of traits' Go values)
    val calls = this.closures.len > 0 || this.traits.len > 0;
    var out = S("// Code generated by voltc bindings. DO NOT EDIT.\n\n");
    out.append(fmt("// Package {}: the Volt package for Go, through cgo. It links\n", S(p)).as_str());
    out.append(fmt("// lib{} (set CGO_LDFLAGS=-L<dir> for where it is). Errors come back as *Error values.\n", S(p)).as_str());
    out.append(fmt("package {}\n\n/*\n", S(p)).as_str());
    out.append(fmt("#cgo LDFLAGS: -l{}\n#include <stdlib.h>\n", S(p)).as_str());
    // only declarations here (and static inline helpers): this file exports Go functions to C, and
    // cgo allows no C definitions next to //export
    var hdr = this.c_text();
    hdr = without_inline_text_free(hdr.as_str());
    out.append(hdr.as_str());
    for (i) in 0..this.closures.len {
        var ps: std::vec<u32> = {};
        val r = this.fn_parts(*this.closures.at(i), &ps);
        var params = S("void *user");
        for (k) in 0..ps.len {
            params.append(fmt2(", {}a{}", spaced(this.c_in(*ps.at(k), false)), unum(@cast<u64>(k))).as_str());
        }
        out.append(fmt4("extern {}{}cb{}({});\n", spaced(this.c_prim(r, false)), S(p), unum(@cast<u64>(i)), move params).as_str());
    }
    out.append(this.go_c_helpers().as_str());
    out.append("*/\nimport \"C\"\n");
    // the Go part
    var g = S("\nimport (\n    \"errors\"\n    \"fmt\"\n    \"os\"\n    \"runtime\"\n    \"runtime/cgo\"\n    \"unsafe\"\n)\n");
    g.append("\nvar _ = fmt.Sprint\nvar _ = os.Exit\nvar _ = runtime.KeepAlive\nvar _ unsafe.Pointer\nvar _ cgo.Handle\n");
    // errors
    g.append("\n// Error is an error a Volt function returned: its code and name. Each code is one value, so\n// errors.Is (or ==) against the package's Err... variables works.\ntype Error struct {\n    Code uint32\n    Name string\n}\n\nfunc (e *Error) Error() string { return e.Name }\n");
    var codes: std::string = {};
    for (c&) in this.all_codes().items() {
        val v = fmt2("{}{}", go_name(c.set.as_str()), go_name(c.name));
        g.append(fmt4("\n// {} is error {} of {}.\nvar {} = ", copy v, S(c.name), copy c.set, copy v).as_str());
        g.append(fmt2("&Error{{Code: {}, Name: \"{}\"}}\n", num(c.code), S(c.name)).as_str());
        codes.append(fmt2("    case {}:\n        return {}\n", num(c.code), copy v).as_str());
    }
    g.append(fmt("\nfunc errorOf(code uint32) error {\n    switch code {\n{}    }\n    return &Error{Code: code, Name: fmt.Sprint(\"error \", code)}\n}\n", move codes).as_str());
    g.append("\n// codeOf is err's code for Volt (a Go function's error): an *Error's, else one no error set has\nfunc codeOf(err error) C.uint32_t {\n    if err == nil {\n        return 0\n    }\n    var e *Error\n    if errors.As(err, &e) && e.Code != 0 {\n        return C.uint32_t(e.Code)\n    }\n    return C.uint32_t(0xffffffff)\n}\n");
    // text and strings
    if (this.uses_str) {
        g.append("\n// a string as a Volt str (the bytes stay Go's; C only reads them during the call)\nfunc goStr(s string) C.volt_str {\n    return C.volt_str{ptr: (*C.uint8_t)(unsafe.Pointer(unsafe.StringData(s))), len: C.size_t(len(s))}\n}\n");
        g.append("\n// a Volt str as a Go string (a copy)\nfunc goString(s C.volt_str) string {\n    return C.GoStringN((*C.char)(unsafe.Pointer(s.ptr)), C.int(s.len))\n}\n");
    }
    if (has_u32(&this.slices, STR)) {
        g.append(fmt2("\n// strings as a Volt slice of strs for a call (pin keeps their bytes where they are until it's\n// unpinned)\nfunc goStrs(xs []string, pin *runtime.Pinner) C.{} {{\n    vs := make([]C.volt_str, len(xs)+1)\n    for i, x := range xs {{\n        if len(x) > 0 {{\n            pin.Pin(unsafe.StringData(x))\n            vs[i] = goStr(x)\n        }}\n    }}\n    return C.{}{{ptr: &vs[0], len: C.size_t(len(xs))}}\n}}\n", this.made_name("slice", STR, false), this.made_name("slice", STR, false)).as_str());
    }
    if (this.texts.len > 0) {
        g.append(fmt("\nfunc takeText(t C.volt_text) string {\n    s := C.GoStringN((*C.char)(unsafe.Pointer(t.ptr)), C.int(t.len))\n    C.{}_text_free(t)\n    return s\n}\n", S(p)).as_str());
        g.append(fmt("\n// text Go gives Volt: a copy in C memory, which Volt frees\nfunc goText(s string) C.volt_text {\n    return C.{}_go_text(C.CBytes([]byte(s)), C.size_t(len(s)))\n}\n", S(p)).as_str());
    }
    if (this.lists.len > 0) {
        g.append(fmt("\n// takeList copies a list Volt gave out into a Go slice (each element through f), then frees it\nfunc takeList[E, G any](ptr *E, n C.size_t, owner unsafe.Pointer, drop *[0]byte, f func(E) G) []G {\n    out := make([]G, int(n))\n    if n > 0 {\n        for i, x := range unsafe.Slice(ptr, int(n)) {\n            out[i] = f(x)\n        }\n    }\n    C.{}_go_drop(drop, owner)\n    return out\n}\n", S(p)).as_str());
    }
    // enums
    for (e&) in this.enums.items() {
        val info = this.c.ei(*e);
        val n = this.go_tname(info.name);
        var w: usize = 0;
        for (i) in 0..info.names.len {
            val c = fmt2("{}{}", copy n, go_name(*info.names.at(i)));
            if (c.len() > w) {
                w = c.len();
            }
        }
        g.append(fmt2("\n// {} is Volt enum {}.\n", copy n, S(info.name)).as_str());
        g.append(fmt2("type {} {}\n\nconst (\n", copy n, this.go_ty(int_id(info.tag))).as_str());
        for (i) in 0..info.names.len {
            val c = fmt2("{}{}", copy n, go_name(*info.names.at(i)));
            g.append(fmt3("    {} {} = {}\n", pad_to(c.as_str(), w), copy n, num(*info.values.at(i))).as_str());
        }
        g.append(")\n");
    }
    // structs
    for (s&) in this.structs.items() {
        if (!this.go_plain(this.c.t.intern(tyk::STRUCT(*s)))) {
            continue;
        }
        val info = this.c.si(*s);
        val n = this.go_tname(info.name);
        val cn = this.c_named(info.name, false);
        // gofmt's columns: the fields' names, and the keys of the conversions' literals
        var w: usize = 0;
        var cw: usize = 0;
        for (f&) in info.fields.items() {
            if (go_name(f.name).len() > w) {
                w = go_name(f.name).len();
            }
            if (f.name.len > cw) {
                cw = f.name.len;
            }
        }
        g.append(fmt2("\n// {} is Volt struct {}.\ntype ", copy n, S(info.name)).as_str());
        g.append(fmt("{} struct {{\n", copy n).as_str());
        var toc: std::string = {};
        var fromc: std::string = {};
        for (f&) in info.fields.items() {
            val gn = go_name(f.name);
            g.append(fmt2("    {} {}\n", pad_to(gn.as_str(), w), this.go_ty(f.ty)).as_str());
            toc.append(fmt2("        {} {},\n", pad_to(fmt("{}:", S(f.name)).as_str(), cw + 1), this.go_to_c(f.ty, fmt("v.{}", copy gn).as_str())).as_str());
            fromc.append(fmt2("        {} {},\n", pad_to(fmt("{}:", copy gn).as_str(), w + 1), this.go_from_c(f.ty, fmt("c.{}", S(f.name)).as_str())).as_str());
        }
        g.append(fmt3("}}\n\nfunc (v {}) c() C.{} {{\n    return C.{}{{\n", copy n, copy cn, copy cn).as_str());
        g.append(toc.as_str());
        g.append(fmt3("    }}\n}}\n\nfunc {}FromC(c C.{}) {} {{\n", copy n, copy cn, copy n).as_str());
        g.append(fmt("    return {}{{\n", copy n).as_str());
        g.append(fromc.as_str());
        g.append("    }\n}\n");
    }
    // what Volt calls back: Go functions, kept by a callback, and exported functions the C side
    // calls with its handle
    if (calls) {
        g.append("\n// a Go value Volt calls (a func, or a trait's value): what it panicked with, re-panicked when the\n// call it was passed to returns, and the C copies of the strs it gave Volt\ntype callback struct {\n    f        any\n    panicked any\n    kept     []unsafe.Pointer\n}\n");
        g.append("\n// catch keeps what a call from Volt panicked with (the first), rather than unwind through C\nfunc (s *callback) catch(v any) {\n    if s.panicked == nil {\n        s.panicked = v\n    }\n}\n");
        if (this.uses_str) {
            g.append("\n// a str Go gives Volt: a copy in C memory, freed when the call s was passed to returns\nfunc (s *callback) str(v string) C.volt_str {\n    p := C.CBytes([]byte(v))\n    s.kept = append(s.kept, p)\n    return C.volt_str{ptr: (*C.uint8_t)(p), len: C.size_t(len(v))}\n}\n");
        }
        g.append("\n// done ends the call s was passed to: it frees the strs s gave Volt, and re-panics what s panicked\n// with\nfunc (s *callback) done() {\n    for _, p := range s.kept {\n        C.free(p)\n    }\n    s.kept = nil\n    if s.panicked != nil {\n        panic(s.panicked)\n    }\n}\n");
        g.append("\n// fatal ends the program: a Go function that had to give Volt a handle panicked, and there's no\n// handle to give it\nfunc fatal(v any) {\n    fmt.Fprintln(os.Stderr, \"panic:\", v, \"(in a Go function giving Volt a handle)\")\n    os.Exit(2)\n}\n");
    }
    for (i) in 0..this.closures.len {
        val ct = *this.closures.at(i);
        var ps: std::vec<u32> = {};
        val r = this.fn_parts(ct, &ps);
        g.append(this.go_export(fmt2("{}cb{}", S(p), unum(@cast<u64>(i))).as_str(), "user", fmt("s.f.({})", this.go_ty(ct)).as_str(), &ps, r).as_str());
    }
    // closures Volt gives out
    for (i) in 0..this.closures.len {
        if (has_u32(&this.closures_out, @cast<u32>(i))) {
            this.go_closure(@cast<u32>(i), &g);
        }
    }
    // traits
    for (k) in 0..this.traits.len {
        this.go_trait(@cast<u32>(k), &g);
    }
    if (this.traits.len > 0) {
        // a Go value given to Volt, which is done with it: its Close runs
        g.append(fmt2("\n//export {}GoDrop\nfunc {}GoDrop(self unsafe.Pointer) {{\n    h := (*cgo.Handle)(self)\n    s := h.Value().(*callback)\n    h.Delete()\n    C.free(self)\n    defer func() {{\n        if v := recover(); v != nil {{\n            s.catch(v)\n        }}\n    }}()\n", S(p), S(p)).as_str());
        g.append("    switch c := s.f.(type) {\n    case interface{ Close() }:\n        c.Close()\n    case interface{ Close() error }:\n        c.Close()\n    }\n}\n");
    }
    // classes
    for (s&) in this.handles.items() {
        val n = this.go_tname(this.c.si(*s).name);
        val cn = this.c_named(this.c.si(*s).name, false);
        var tpl = S("\n// $N is Volt export struct $V. Close frees it (or the garbage collector does).\ntype $N struct {\n    h    *C.$C\n    lent bool // Volt lent it: never freed here, and not Go's to give\n}\n\nfunc wrap$N(h *C.$C) *$N {\n    if h == nil {\n        return nil\n    }\n    o := &$N{h: h}\n    runtime.SetFinalizer(o, (*$N).Close)\n    return o\n}\n");
        tpl.append("\n// Close frees the handle (once; later calls do nothing).\nfunc (o *$N) Close() {\n    if o.h != nil {\n        if !o.lent {\n            C.$F(o.h)\n        }\n        o.h = nil\n        runtime.SetFinalizer(o, nil)\n    }\n}\n");
        tpl.append("\nfunc (o *$N) handle() *C.$C {\n    if o.h == nil {\n        panic(\"$N: used after Close, or after the Volt call that lent it\")\n    }\n    return o.h\n}\n");
        tpl.append("\n// owned is the handle, to give to Volt (not one Volt lent)\nfunc (o *$N) owned() *C.$C {\n    if o.lent {\n        panic(\"$N: Volt lent it, so it isn't Go's to give\")\n    }\n    return o.handle()\n}\n");
        tpl.append("\n// forget lets go of the handle: it's Volt's from here\nfunc (o *$N) forget() {\n    o.h = nil\n    runtime.SetFinalizer(o, nil)\n}\n");
        tpl.append("\n// give gives the handle to Volt\nfunc (o *$N) give() *C.$C {\n    h := o.owned()\n    o.forget()\n    return h\n}\n");
        tpl = replace_all(tpl.as_str(), "$N", n.as_str());
        tpl = replace_all(tpl.as_str(), "$V", this.c.si(*s).name);
        tpl = replace_all(tpl.as_str(), "$C", cn.as_str());
        g.append(replace_all(tpl.as_str(), "$F", this.free_name(*s).as_str()).as_str());
        for (e&) in ents.items() {
            if (e.free_of != null) {
                continue;
            }
            val m = this.member_of(e.f, *s) ?? continue;
            val info = this.c.fi(e.f);
            if (this.node_is_method(e.f, *s)) {
                val args = this.go_args(e.f, 1);
                g.append("\n");
                g.append(this.go_doc(e.f, go_name(m).as_str()).as_str());
                g.append(fmt4("func (o *{}) {}({}){} {{\n", copy n, go_name(m), go_decls(&args), this.go_results(info.ret)).as_str());
                g.append(indent(this.go_body(e.f, &args, "o.handle()").as_str()).as_str());
                g.append("}\n");
            } else {
                // New for new, NewX... for the others
                var fname = fmt("New{}", copy n);
                if (m != "new") {
                    fname = fmt2("{}{}", copy n, go_name(m));
                }
                val args = this.go_args(e.f, 0);
                g.append("\n");
                g.append(this.go_doc(e.f, fname.as_str()).as_str());
                g.append(fmt3("func {}({}){} {{\n", copy fname, go_decls(&args), this.go_results(info.ret)).as_str());
                g.append(indent(this.go_body(e.f, &args, null).as_str()).as_str());
                g.append("}\n");
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
        g.append("\n");
        g.append(this.go_doc(e.f, gn.as_str()).as_str());
        g.append(fmt3("func {}({}){} {{\n", copy gn, go_decls(&args), this.go_results(info.ret)).as_str());
        g.append(indent(this.go_body(e.f, &args, null).as_str()).as_str());
        g.append("}\n");
    }
    out.append(go_tabs(g.as_str()).as_str());
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
// Every C form crosses. A class instance holds a handle (and lets go of it when it's given to Volt),
// a callback is any function and a trait any object with its methods (lent for a call, or given:
// held until Volt drops it), and what Volt gives out frees itself: text and lists are copied out,
// and Volt's closures and trait values are functions and classes with close() and Symbol.dispose
// (freed when collected otherwise). A callback runs on the JS thread that made the call; what it
// throws is kept, Volt gets a stand-in, and the call throws it once it's back

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

// C statements reading JS value js into C lvalue c (of type t), as a callback gives it back or an
// array holds it; they `goto fail` with a JS exception thrown when js doesn't fit. A str's bytes are
// kept (see vn_kept), text is given to Volt, and so is a handle (its instance lets go of it)
attach fn node_get(this: bind&, t: u32, js: str, c: str) -> compile_error!std::string {
    if (this.node_simple(t)) {
        return this.node_get_simple(t, js, c);
    }
    val h = this.lent_handle(t);
    if (h) {
        val g = fmt4("if (!vn_unwrap(env, {}, vn_tags_{}, 0, (void **)&{}, \"{}\")) { goto fail; }", S(js), this.node_sname(h), S(c), this.node_sname(h));
        if (this.is_ref(t)) {
            return g;
        }
        return fmt2("if (!vn_is_nullish(env, {})) {{ {} }}", S(js), copy g);
    }
    match (this.shape_of(t) ?? shape::VOID) {
        .STR => { return fmt2("if (!vn_str_kept(env, {}, &{})) { goto fail; }", S(js), S(c)); },
        .CSTR => { return fmt2("if (!vn_cstr_kept(env, {}, &{})) { goto fail; }", S(js), S(c)); },
        .TEXT(x) => { return fmt2("if (!vn_text(env, {}, &{})) { goto fail; }", S(js), S(c)); },
        .HANDLE(s) => {
            val sn = this.node_sname(s);
            var g = fmt4("if (!vn_unwrap(env, {}, vn_tags_{}, 1, (void **)&{}, \"{}\")) { goto fail; }", S(js), copy sn, S(c), copy sn);
            g.append(fmt(" vn_detach(env, {});", S(js)).as_str());
            return g;
        },
        .OPT(x) => {
            var g = fmt4("memset(&{}, 0, sizeof {}); if (!vn_is_nullish(env, {})) {{ {}.has = true; ", S(c), S(c), S(js), S(c));
            g.append((try this.node_get(x, js, fmt("{}.value", S(c)).as_str())).as_str());
            g.append(" }");
            return g;
        },
        .RESULT(e, x) => {
            // the value (an error is thrown)
            if (x == VOID) {
                return {};
            }
            return try this.node_get(x, js, fmt("{}.value", S(c)).as_str());
        },
        .PTR(x) => { return fmt2("if (!vn_external(env, {}, (void **)&{})) { goto fail; }", S(js), S(c)); },
        .FN(i) => { return fmt2("if (!vn_external(env, {}, (void **)&{})) { goto fail; }", S(js), S(c)); },
        default => { return fail(NO_SPAN, fmt("{} can't come from JavaScript", this.c.ty_name(t))); },
    }
}

// C statements making JS value dst of C value c (of type t), as Volt gives it: text and lists are
// copied out and freed, a handle, a closure or a trait's value is held by an object that frees it;
// d tells nested loops' indexes apart
attach fn node_put(this: bind&, t: u32, c: str, dst: str, d: u32) -> compile_error!std::string {
    if (this.node_simple(t)) {
        return fmt2("{} = {};", S(dst), this.node_put_simple(t, c));
    }
    match (this.shape_of(t) ?? shape::VOID) {
        .STR => { return fmt3("{} = vn_from_str(env, {}.ptr, {}.len);", S(dst), S(c), S(c)); },
        .CSTR => { return fmt2("{} = vn_from_cstr(env, {});", S(dst), S(c)); },
        .TEXT(x) => { return fmt2("{} = vn_take_text(env, {});", S(dst), S(c)); },
        .HANDLE(s) => { return fmt3("{} = vn_wrap_{}(env, {});", S(dst), this.node_sname(s), S(c)); },
        .OPT(x) => {
            // an optional handle is its pointer (null: none)
            val h = this.handle_of(x);
            if (h) {
                return fmt4("{} = {} ? vn_wrap_{}(env, {}) : vn_null(env);", S(dst), S(c), this.node_sname(h), S(c));
            }
            val v = try this.node_put(x, fmt("{}.value", S(c)).as_str(), dst, d);
            return fmt3("if ({}.has) {{ {} }} else {{ {} = vn_null(env); }}", S(c), copy v, S(dst));
        },
        .SLICE(x) => { return try this.node_array(x, c, dst, d); },
        .LIST(x) => {
            // text copied out of its str, a handle held by its instance; then the list freed
            var e = this.list_elem(t);
            if (this.view_of(e) == STR) {
                e = STR;
            }
            var out = try this.node_array(e, c, dst, d);
            out.append(fmt(" volt_list_free({});", S(c)).as_str());
            return out;
        },
        .CLOSURE(i) => { return fmt3("{} = vn_make_fn(env, &{}, vn_call_closure{});", S(dst), S(c), unum(@cast<u64>(i))); },
        .TRAIT(i) => { return fmt3("{} = vn_wrap_obj(env, vn_class_volt_{}, &{});", S(dst), this.short(this.trait_of(t)), S(c)); },
        .PTR(x) => { return fmt2("{} = vn_from_external(env, (void *){});", S(dst), S(c)); },
        .FN(i) => { return fmt2("{} = vn_from_external(env, (void *){});", S(dst), S(c)); },
        default => { return fail(NO_SPAN, fmt("{} can't go to JavaScript", this.c.ty_name(t))); },
    }
}

// C statements making JS array dst of the elements (of type e) of C slice or list c
attach fn node_array(this: bind&, e: u32, c: str, dst: str, d: u32) -> compile_error!std::string {
    val i = fmt("i{}", unum(@cast<u64>(d)));
    val x = fmt("e{}", unum(@cast<u64>(d)));
    val put = try this.node_put(e, fmt2("{}.ptr[{}]", S(c), copy i).as_str(), x.as_str(), d + 1);
    var out = fmt4("napi_create_array_with_length(env, {}.len, &{}); for (size_t {} = 0; {} < ", S(c), S(dst), copy i, copy i);
    out.append(fmt4("{}.len; {}++) {{ napi_value {} = NULL; {}", S(c), copy i, copy x, copy put).as_str());
    out.append(fmt3(" napi_set_element(env, {}, (uint32_t){}, {}); }", S(dst), copy i, copy x).as_str());
    return out;
}

// one argument of a JS call into Volt: its C local(s) (decl), the statements that fill them from js
// (get), what runs once every argument is in (give: what the call takes over), what the call passes
// (pass), what runs after the call (after: writing back into JS objects and arrays) and what frees
// its temporaries (cleanup); gives: it adds to the call's gives (see vn_gives)
struct node_arg {
    decl: std::string = {};
    get: std::string = {};
    give: std::string = {};
    pass: std::string = {};
    after: std::string = {};
    cleanup: std::string = {};
    gives: bool = false;
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
        a.get = fmt4("if (!vn_unwrap(env, {}, vn_tags_{}, 0, (void **)&{}, \"{}\")) { goto fail; }", S(js), this.node_sname(h), S(c), this.node_sname(h));
        a.pass = S(c);
        return;
    }
    if (this.in_ty(t) == STR) {
        // a str, or owned text (Volt copies it)
        a.decl = fmt2("volt_str {}; char *{}_buf = NULL;", S(c), S(c));
        a.get = fmt3("if (!vn_str(env, {}, &{}, &{}_buf)) { goto fail; }", S(js), S(c), S(c));
        a.pass = S(c);
        a.cleanup = fmt("free({}_buf);", S(c));
        return;
    }
    match (this.shape_of(t) ?? shape::VOID) {
        .CSTR => {
            a.decl = fmt2("const char *{} = NULL; char *{}_buf = NULL;", S(c), S(c));
            a.get = fmt3("if (!vn_cstr(env, {}, &{}, &{}_buf)) { goto fail; }", S(js), S(c), S(c));
            a.pass = S(c);
            a.cleanup = fmt("free({}_buf);", S(c));
        },
        .HANDLE(s) => {
            // given to Volt: its instance lets go of it once every argument is in
            val sn = this.node_sname(s);
            a.decl = fmt2("{}{} = NULL;", spaced(this.handle_c(s, false)), S(c));
            a.get = fmt4("if (!vn_unwrap(env, {}, vn_tags_{}, 1, (void **)&{}, \"{}\")", S(js), copy sn, S(c), copy sn);
            a.get.append(fmt2(" || !vn_add_give(env, &gives, {}, {}, 0)) { goto fail; }", S(js), S(c)).as_str());
            a.pass = S(c);
            a.gives = true;
        },
        .TRAIT(i) => {
            // a JS object with the trait's fns (lent, or given: held until Volt drops it), or Volt's
            // own value (lent, or given back)
            val tr = this.short(this.trait_of(t));
            a.decl = fmt2("{} {};", this.c_prim(t, false), S(c));
            var lent = S("NULL");
            var g = S("&gives");
            if (this.is_ref(t)) {
                a.decl.append(fmt(" struct vn_obj {}_o;", S(c)).as_str());
                lent = fmt("&{}_o", S(c));
                g = S("NULL");
            } else {
                a.give = fmt4("if ({}.vt == &vn_vt_{}) {{ {}.self = vn_obj_new(env, {}); }}", S(c), copy tr, S(c), S(js));
                a.gives = true;
            }
            a.get = fmt5("if (!vn_get_obj(env, {}, vn_tags_volt_{}, &vn_vt_{}, vn_fns_{}, \"{}\", ", S(js), copy tr, copy tr, copy tr, copy tr);
            a.get.append(fmt3("{}, {}, &{})) { goto fail; }", copy lent, copy g, S(c)).as_str());
            a.pass = S(c);
        },
        .LIST(x) => {
            // given to Volt, which copies the elements (and takes the handles)
            try this.node_elems(this.list_elem(t), true, js, c, a);
        },
        .SLICE(x) => {
            try this.node_elems(this.slice_elem(t), false, js, c, a);
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
        .OPT(x) => {
            val oh = this.handle_of(x);
            if (oh) {
                // given to Volt (null: none)
                val sn = this.node_sname(oh);
                a.decl = fmt2("{}{} = NULL;", spaced(this.handle_c(oh, false)), S(c));
                a.get = fmt5("if (!vn_is_nullish(env, {}) && (!vn_unwrap(env, {}, vn_tags_{}, 1, (void **)&{}, \"{}\")", S(js), S(js), copy sn, S(c), copy sn);
                a.get.append(fmt2(" || !vn_add_give(env, &gives, {}, {}, 0))) { goto fail; }", S(js), S(c)).as_str());
                a.pass = S(c);
                a.gives = true;
                return;
            }
            if (this.in_ty(x) == STR) {
                // a str?, or an optional text (Volt copies it)
                a.decl = fmt3("{} {}; char *{}_buf = NULL;", this.c_prim(this.in_ty(t), false), S(c), S(c));
                a.get = fmt4("memset(&{}, 0, sizeof {}); if (!vn_is_nullish(env, {})) {{ {}.has = true; ", S(c), S(c), S(js), S(c));
                a.get.append(fmt3("if (!vn_str(env, {}, &{}.value, &{}_buf)) { goto fail; } }", S(js), S(c), S(c)).as_str());
                a.pass = S(c);
                a.cleanup = fmt("free({}_buf);", S(c));
                return;
            }
            a.decl = fmt2("{} {};", this.c_prim(t, false), S(c));
            a.get = try this.node_get(t, js, c);
            a.pass = S(c);
        },
        .CLOSURE(i) => {
            a.decl = fmt("struct vn_cb {}_cb;", S(c));
            a.get = fmt4("if (!vn_function(env, {})) { goto fail; } {}_cb.env = env; {}_cb.fn = {};", S(js), S(c), S(c), S(js));
            a.pass = fmt2("vn_cb{}, &{}_cb", unum(@cast<u64>(i)), S(c));
        },
        default => {
            return fail(NO_SPAN, fmt("{} can't come from JavaScript", this.c.ty_name(t)));
        },
    }
    return;
}

// a slice's or a list's elements from a JS array (elem: the element type; given: a list's, which
// Volt takes): strings for text, class instances for handles (lent, or given up), the value or null
// for an optional, and numbers and structs as C holds them (what Volt writes into a slice's comes
// back into the array)
attach fn node_elems(this: bind&, elem: u32, given: bool, js: str, c: str, a: node_arg&) -> compile_error!void {
    val v = this.view_of(elem);
    val st = this.made_name("slice", v, false);
    val h = this.handle_of(elem);
    a.pass = S(c);
    if (v == STR) {
        a.decl = fmt3("{} {}; volt_str *{}_buf = NULL; ", copy st, S(c), S(c));
        a.decl.append(fmt("uint32_t {}_n = 0;", S(c)).as_str());
        a.get = fmt3("if (!vn_strs(env, {}, &{}_buf, &{}_n)) { goto fail; } ", S(js), S(c), S(c));
        a.get.append(fmt4("{}.ptr = {}_buf; {}.len = {}_n;", S(c), S(c), S(c), S(c)).as_str());
        a.cleanup = fmt2("vn_free_strs({}_buf, {}_n);", S(c), S(c));
        return;
    }
    if (h) {
        val sn = this.node_sname(h);
        var g = S("NULL");
        if (given) {
            g = S("&gives");
            a.gives = true;
        }
        a.decl = fmt3("{} {}; void **{}_buf = NULL; ", copy st, S(c), S(c));
        a.decl.append(fmt("uint32_t {}_n = 0;", S(c)).as_str());
        a.get = fmt5("if (!vn_handles(env, {}, vn_tags_{}, \"{}\", {}, &{}_buf, ", S(js), copy sn, copy sn, copy g, S(c));
        a.get.append(fmt5("&{}_n)) { goto fail; } {}.ptr = ({} **){}_buf; {}.len = ", S(c), S(c), this.c_named(this.c.si(h).name, false), S(c), S(c)).as_str());
        a.get.append(fmt("{}_n;", S(c)).as_str());
        a.cleanup = fmt("free({}_buf);", S(c));
        return;
    }
    // values as C holds them
    val et = this.c_prim(v, false);
    val get = try this.node_get(v, "e", fmt("{}_buf[i]", S(c)).as_str());
    a.decl = fmt3("{} {}; {} *", copy st, S(c), copy et);
    a.decl.append(fmt2("{}_buf = NULL; uint32_t {}_n = 0;", S(c), S(c)).as_str());
    a.get = fmt3("if (!vn_array(env, {}, &{}_n)) { goto fail; } {}_buf = ", S(js), S(c), S(c));
    a.get.append(fmt3("calloc({}_n ? {}_n : 1, sizeof({}));", S(c), S(c), copy et).as_str());
    a.get.append(fmt(" if (!{}_buf) {{ vn_throw(env, \"out of memory\"); goto fail; }}", S(c)).as_str());
    a.get.append(fmt3(" for (uint32_t i = 0; i < {}_n; i++) {{ napi_value e; napi_get_element(env, {}, i, &e); {} }}", S(c), S(js), copy get).as_str());
    a.get.append(fmt4(" {}.ptr = {}_buf; {}.len = {}_n;", S(c), S(c), S(c), S(c)).as_str());
    a.cleanup = fmt("free({}_buf);", S(c));
    if (!given && this.node_simple(v)) {
        // what Volt wrote into the elements comes back
        a.after = fmt3("for (uint32_t i = 0; i < {}_n; i++) napi_set_element(env, {}, i, {});", S(c), S(js), this.node_put_simple(v, fmt("{}_buf[i]", S(c)).as_str()));
    }
}

// which vn_set_ writes a C value back into a JS object (a struct's fields)
attach fn node_ptr_set_name(this: bind&, x: u32) -> std::string {
    match (this.shape_of(x) ?? shape::VOID) {
        .STRUCT(s) => { return this.node_sname(s); },
        default => { return S("none"); },
    }
}

// C statements that turn C result r (of type t) into JS value `result`; an error result throws (what
// a callback threw, when that's why)
attach fn node_result(this: bind&, t: u32, r: str) -> compile_error!std::string {
    if (t == VOID) {
        return S("napi_get_undefined(env, &result);");
    }
    match (this.shape_of(t) ?? shape::VOID) {
        .RESULT(e, x) => {
            var out = fmt2("if ({}.error != 0) {{ vn_throw_err(env, {}.error, thrown); goto fail; }} ", S(r), S(r));
            out.append((try this.node_result(x, fmt("{}.value", S(r)).as_str())).as_str());
            return out;
        },
        default => { return try this.node_put(t, r, "result", 0); },
    }
}

// the C function behind a JS function calling into Volt: name; what (its name in messages); its
// params' types (ps) and C names, from argv; self_decl and self_get, what find what it's called on;
// callee, what it calls, with first before the params; ret, the result's type. Every argument is
// converted before anything is given (so a failing one leaks nothing), and what a callback threw
// during the call is thrown once it's back
attach fn node_call(this: bind&, name: str, what: str, ps: std::vec<u32>&, names: std::vec<std::string>&, self_decl: str, self_get: str, callee: str, first: str, ret: u32, out: std::string&) -> compile_error!void {
    var decls: std::string = {};
    var gets: std::string = {};
    var gives: std::string = {};
    var passes = S(first);
    var afters: std::string = {};
    var cleanups: std::string = {};
    var any_give = false;
    var required: usize = 0;
    for (k) in 0..ps.len {
        val t = *ps.at(k);
        var a: node_arg = {};
        val js = fmt("argv[{}]", unum(@cast<u64>(k)));
        try this.node_arg_of(t, js.as_str(), names.at(k).as_str(), &a);
        decls.append(fmt("    {}\n", copy a.decl).as_str());
        gets.append(fmt("    {}\n", copy a.get).as_str());
        if (a.give.len() > 0) {
            gives.append(fmt("    {}\n", copy a.give).as_str());
        }
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
        if (a.gives) {
            any_give = true;
        }
        match (this.shape_of(t) ?? shape::VOID) {
            .OPT(x) => {},
            default => { required = k + 1; },
        }
    }
    var argn = ps.len;
    if (argn == 0) {
        argn = 1;
    }
    out.append(fmt3("\nstatic napi_value {}(napi_env env, napi_callback_info info) {{\n    size_t argc = {};\n    napi_value argv[{}], self = NULL, result = NULL, saved = NULL, thrown = NULL;\n    void *data = NULL;\n    size_t busy = vn_nbusy;\n", S(name), unum(@cast<u64>(ps.len)), unum(@cast<u64>(argn))).as_str());
    out.append(self_decl);
    out.append(decls.as_str());
    if (any_give) {
        out.append("    struct vn_gives gives = {NULL, 0, 0};\n");
    }
    out.append("    if (napi_get_cb_info(env, info, &argc, argv, &self, &data) != napi_ok) {\n        return NULL;\n    }\n    (void)self;\n    (void)data;\n");
    if (required > 0) {
        out.append(fmt3("    if (argc < {}) {{\n        napi_throw_type_error(env, NULL, \"{} takes {} arguments\");\n        return NULL;\n    }}\n", unum(@cast<u64>(required)), S(what), unum(@cast<u64>(required))).as_str());
    }
    out.append(self_get);
    out.append(gets.as_str());
    if (any_give) {
        out.append("    vn_give_all(env, &gives);\n");
    }
    out.append(gives.as_str());
    out.append("    if (0) {\n        goto fail;\n    }\n    saved = vn_thrown;\n    vn_thrown = NULL;\n    {\n");
    val call = fmt2("{}({})", S(callee), copy passes);
    if (ret == VOID) {
        out.append(fmt("        {};\n", copy call).as_str());
    } else {
        out.append(fmt2("        {}r = {};\n", spaced(this.c_out(ret, false)), copy call).as_str());
    }
    out.append("        thrown = vn_thrown;\n        vn_thrown = saved;\n");
    // the result first: an error throws (goto fail) before anything is written back
    out.append(fmt("        {}\n", try this.node_result(ret, "r")).as_str());
    out.append(afters.as_str());
    out.append("        if (thrown) {\n            napi_throw(env, thrown);\n            result = NULL;\n        }\n    }\nfail:\n");
    out.append(cleanups.as_str());
    if (any_give) {
        out.append("    free(gives.at);\n");
    }
    // what was lent to this call isn't any more
    out.append("    vn_nbusy = busy;\n    return result;\n}\n");
    return;
}

// the C function behind one JS function (self: the export struct a method's this is, if any)
attach fn node_fn(this: bind&, f: u32, wname: str, self_class: u32?, out: std::string&) -> compile_error!void {
    val info = this.c.fi(f);
    var first: usize = 0;
    var self_decl: std::string = {};
    var self_get: std::string = {};
    var pass: std::string = {};
    val sc = self_class;
    if (sc) {
        first = 1;
        self_decl = fmt("    {}p_self = NULL;\n", spaced(this.handle_c(sc, false)));
        self_get = fmt2("    if (!vn_unwrap(env, self, vn_tags_{}, 0, (void **)&p_self, \"{}\")) {\n        goto fail;\n    }\n", this.node_sname(sc), this.node_sname(sc));
        pass = S("p_self");
    }
    var ps: std::vec<u32> = {};
    var names: std::vec<std::string> = {};
    for (k) in first..info.params.len {
        put(&ps, info.params.at(k).ty);
        put(&names, fmt("p_{}", S(info.params.at(k).name)));
    }
    try this.node_call(wname, info.c_name, &ps, &names, self_decl.as_str(), self_get.as_str(), info.c_name, pass.as_str(), info.ret, out);
    return;
}

// a C function Volt calls JS through (a callback's, or the fn of a trait a JS object implements):
// sig is its signature, head its first lines (env, and c: what it calls), call the C expression
// calling JS (true when it returned); ps are the params' types (a0..), r the result's. A handle Volt
// lends is an instance that lets go of it when the call returns, and a struct or a slice Volt lends
// gets back what JS wrote into it. What JS throws (or gives back that doesn't fit) is kept for the
// Volt call it's in, and Volt gets a stand-in (see node_standin)
attach fn node_upcall(this: bind&, sig: std::string, head: str, call: str, ps: std::vec<u32>&, r: u32) -> compile_error!std::string {
    var argn = ps.len;
    if (argn == 0) {
        argn = 1;
    }
    var out = fmt3("\nstatic {} {{\n{}    napi_escapable_handle_scope scope = NULL;\n    napi_value argv[{}], ret = NULL, err = NULL;\n", copy sig, S(head), unum(@cast<u64>(argn)));
    if (r != VOID) {
        out.append(fmt("    {}out;\n    memset(&out, 0, sizeof out);\n", spaced(this.c_prim(r, false))).as_str());
    }
    out.append("    napi_open_escapable_handle_scope(env, &scope);\n");
    var back: std::string = {};
    var unlend: std::string = {};
    for (k) in 0..ps.len {
        val p = *ps.at(k);
        val a = fmt("a{}", unum(@cast<u64>(k)));
        val av = fmt("argv[{}]", unum(@cast<u64>(k)));
        val h = this.lent_handle(p);
        if (h) {
            if (this.is_ref(p)) {
                out.append(fmt3("    {} = vn_lend_{}(env, {});\n", copy av, this.node_sname(h), copy a).as_str());
            } else {
                out.append(fmt4("    {} = {} ? vn_lend_{}(env, {}) : vn_null(env);\n", copy av, copy a, this.node_sname(h), copy a).as_str());
            }
            unlend.append(fmt("    vn_detach(env, {});\n", copy av).as_str());
            continue;
        }
        var done = false;
        match (this.shape_of(p) ?? shape::VOID) {
            .PTR(x) => {
                match (this.shape_of(x) ?? shape::VOID) {
                    .STRUCT(s) => {
                        if (this.node_simple(x)) {
                            // a struct Volt lends: a copy, and what JS changed in it goes back
                            val sn = this.node_sname(s);
                            out.append(fmt4("    {} = {} ? vn_new_{}(env, {}) : vn_null(env);\n", copy av, copy a, copy sn, copy a).as_str());
                            back.append(fmt4("    if ({} && !vn_get_{}(env, {}, {})) {{\n        goto fail;\n    }}\n", copy a, copy sn, copy av, copy a).as_str());
                            done = true;
                        }
                    },
                    default => {},
                }
            },
            .SLICE(x) => {
                if (this.node_simple(x)) {
                    // what JS wrote into the array goes back into Volt's elements
                    back.append(fmt3("    for (size_t i = 0; i < {}.len; i++) {{\n        napi_value e = NULL;\n        napi_get_element(env, {}, (uint32_t)i, &e);\n        {}\n    }}\n", copy a, copy av, this.node_get_simple(x, "e", fmt("{}.ptr[i]", copy a).as_str())).as_str());
                }
            },
            default => {},
        }
        if (!done) {
            out.append(fmt("    {}\n", try this.node_put(this.in_ty(p), a.as_str(), av.as_str(), 0)).as_str());
        }
    }
    out.append(fmt("    if (!({})) {{\n        goto fail;\n    }}\n", S(call)).as_str());
    out.append(back.as_str());
    if (r != VOID) {
        out.append(fmt("    {}\n", try this.node_get(r, "ret", "out")).as_str());
    }
    out.append(unlend.as_str());
    out.append("    napi_close_escapable_handle_scope(env, scope);\n");
    var ret = S("    return;\n");
    if (r != VOID) {
        ret = S("    return out;\n");
    }
    out.append(ret.as_str());
    // the exception taken first: napi does nothing else while one is pending
    out.append("fail:\n    err = vn_caught(env);\n");
    out.append(unlend.as_str());
    out.append(this.node_standin(r).as_str());
    out.append("    napi_close_escapable_handle_scope(env, scope);\n");
    out.append(ret.as_str());
    out.append("}\n");
    return out;
}

// what an upcall gives Volt when JS threw err (kept for the Volt call, which throws it): for E!T
// the error a thrown VoltError names (then nothing is kept), else the error set's first; empty text;
// zero; a handle has no stand-in, so the program stops, as a Volt panic does
attach fn node_standin(this: bind&, r: u32) -> std::string {
    val keep = "    vn_keep(env, scope, err);\n";
    val h = this.lent_handle(r);
    if (h) {
        if (this.is_ref(r)) {
            return fmt("    vn_fatal(env, err, \"a callback giving a {} threw\");\n", this.node_sname(h));
        }
        return S(keep);
    }
    match (this.shape_of(r) ?? shape::VOID) {
        .HANDLE(s) => { return fmt("    vn_fatal(env, err, \"a callback giving a {} threw\");\n", this.node_sname(s)); },
        .TEXT(x) => { return fmt("{}    out.ptr = (const uint8_t *)\"\";\n    out.drop = vn_no_drop;\n", S(keep)); },
        .CSTR => { return fmt("{}    out = \"\";\n", S(keep)); },
        .RESULT(e, x) => {
            val set = this.node_codes(e);
            var out = fmt("    out.error = vn_code_of(env, err, {});\n    if (!out.error) {\n", copy set);
            out.append(fmt2("        out.error = {}[0] ? {}[0] : 1;\n        vn_keep(env, scope, err);\n    }\n", copy set, copy set).as_str());
            return out;
        },
        default => { return S(keep); },
    }
}

// the codes (see node_text) of error set type e
attach fn node_codes(this: bind&, e: u32) -> std::string {
    match (*this.c.t.get(e)) {
        .ENUM(x) => { return fmt("vn_codes_{}", this.local(this.c.ei(x).name)); },
        default => { return S("vn_codes_all"); },
    }
}

// does an export fn take closure type i as a callback (which JS gives as a function)?
attach fn node_cb_used(this: bind&, i: u32) -> bool {
    for (f&) in this.exports().items() {
        for (p&) in this.c.fi(*f).params.items() {
            match (this.shape_of(p.ty) ?? shape::VOID) {
                .CLOSURE(j) => {
                    if (j == i) {
                        return true;
                    }
                },
                default => {},
            }
        }
    }
    return false;
}

// two stable 128-bit tags for class name: its instances JS owns, and those lent to a callback (so a
// function can check what it's given)
attach fn node_tags(this: bind&, name: str) -> std::string {
    var n = S(this.pkg);
    n.append("::");
    n.append(name);
    val a = fnv64(n.as_str());
    n.append("#");
    val b = fnv64(n.as_str());
    n.append("lent");
    val c = fnv64(n.as_str());
    n.append("#");
    val d = fnv64(n.as_str());
    var out = fmt2("{{{{0x{}ULL, 0x{}ULL}}, ", hex_u64(a), hex_u64(b));
    out.append(fmt2("{{0x{}ULL, 0x{}ULL}}}}", hex_u64(c), hex_u64(d)).as_str());
    return out;
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
    out.append("// what the calls that are running hold lent (handles, Volt's trait values, its closures being called):\n// closing one, or giving it to Volt, has to wait until the call is back. Each call drops what it\n// added when it returns\nstatic _Thread_local void **vn_busy;\nstatic _Thread_local size_t vn_nbusy, vn_cap_busy;\n\nstatic inline int vn_busy_add(napi_env env, void *p) {\n    if (vn_nbusy == vn_cap_busy) {\n        size_t cap = vn_cap_busy ? vn_cap_busy * 2 : 8;\n        void **b = realloc(vn_busy, cap * sizeof *b);\n        if (!b) {\n            return vn_throw(env, \"out of memory\");\n        }\n        vn_busy = b;\n        vn_cap_busy = cap;\n    }\n    vn_busy[vn_nbusy++] = p;\n    return 1;\n}\n\n// 1 when p isn't lent to a call that's running; else it throws\nstatic inline int vn_busy_check(napi_env env, void *p, const char *what) {\n    char msg[160];\n    for (size_t i = 0; i < vn_nbusy; i++) {\n        if (vn_busy[i] == p) {\n            snprintf(msg, sizeof msg, \"this %s is lent to a call that hasn't returned\", what);\n            return vn_throw(env, msg);\n        }\n    }\n    return 1;\n}\n\n// a class instance's handle (after a check that it is one: own asks for one JavaScript owns, which\n// it can give up, not one lent to a callback or to a call that's running), or an error once it's\n// closed; one that isn't given is lent until the call is back\nstatic inline int vn_unwrap(napi_env env, napi_value v, const napi_type_tag *tags, int own, void **out, const char *what) {\n    bool is = false, lent = false;\n    char msg[160];\n    napi_check_object_type_tag(env, v, &tags[0], &is);\n    if (!is) {\n        napi_check_object_type_tag(env, v, &tags[1], &lent);\n    }\n    if (!is && !lent) {\n        snprintf(msg, sizeof msg, \"expected a %s\", what);\n        return vn_throw(env, msg);\n    }\n    if (lent && own) {\n        snprintf(msg, sizeof msg, \"this %s is lent to a callback, which can't give it away\", what);\n        return vn_throw(env, msg);\n    }\n    if (napi_unwrap(env, v, out) != napi_ok || !*out) {\n        snprintf(msg, sizeof msg, \"this %s is closed\", what);\n        return vn_throw(env, msg);\n    }\n    return own ? vn_busy_check(env, *out, what) : vn_busy_add(env, *out);\n}\n\n// an instance lets go of its handle (given up, or lent no longer)\nstatic inline void vn_detach(napi_env env, napi_value v) {\n    void *h = NULL;\n    napi_remove_wrap(env, v, &h);\n}\n\n");
    out.append("static inline napi_value vn_num(napi_env env, double d) {\n    napi_value v = NULL;\n    napi_create_double(env, d, &v);\n    return v;\n}\n\nstatic inline napi_value vn_from_bool(napi_env env, bool b) {\n    napi_value v = NULL;\n    napi_get_boolean(env, b, &v);\n    return v;\n}\n\nstatic inline napi_value vn_from_str(napi_env env, const uint8_t *p, size_t n) {\n    napi_value v = NULL;\n    napi_create_string_utf8(env, (const char *)p, n, &v);\n    return v;\n}\n\nstatic inline napi_value vn_from_cstr(napi_env env, const char *s) {\n    napi_value v = NULL;\n    if (s) {\n        napi_create_string_utf8(env, s, NAPI_AUTO_LENGTH, &v);\n    } else {\n        napi_get_null(env, &v);\n    }\n    return v;\n}\n\nstatic inline napi_value vn_from_external(napi_env env, void *p) {\n    napi_value v = NULL;\n    if (p) {\n        napi_create_external(env, p, NULL, NULL, &v);\n    } else {\n        napi_get_null(env, &v);\n    }\n    return v;\n}\n\n");
    // errors: an Error whose code is the error's name
    out.append("static inline const char *vn_error_name(uint32_t code) {\n    switch (code) {\n");
    for (c&) in this.all_codes().items() {
        out.append(fmt2("    case {}u: return \"{}\";\n", num(c.code), S(c.name)).as_str());
    }
    out.append("    }\n    return \"ERROR\";\n}\n\n");
    out.append("// the Error for a Volt error code: its code and message are the error's name, its errno the code\nstatic inline napi_value vn_code_error(napi_env env, uint32_t code) {\n    napi_value msg = NULL, name = NULL, err = NULL, num = NULL;\n    napi_create_string_utf8(env, vn_error_name(code), NAPI_AUTO_LENGTH, &name);\n    napi_create_string_utf8(env, vn_error_name(code), NAPI_AUTO_LENGTH, &msg);\n    napi_create_error(env, name, msg, &err);\n    napi_create_uint32(env, code, &num);\n    napi_set_named_property(env, err, \"errno\", num);\n    return err;\n}\n\nstatic inline void vn_throw_code(napi_env env, uint32_t code) {\n    napi_throw(env, vn_code_error(env, code));\n}\n");
    // every error's code, then each error set's (each ends with 0)
    out.append("\n// every error's code, then each error set's (each ends with 0)\nstatic const uint32_t vn_codes_all[] = {");
    for (c&) in this.all_codes().items() {
        out.append(fmt("{}u, ", num(c.code)).as_str());
    }
    out.append("0};\n");
    for (et&) in this.codes.items() {
        match (*this.c.t.get(*et)) {
            .ENUM(e) => {
                val info = this.c.ei(e);
                out.append(fmt("static const uint32_t vn_codes_{}[] = {{", this.local(info.name)).as_str());
                for (i) in 0..info.names.len {
                    out.append(fmt("{}u, ", num(*info.values.at(i))).as_str());
                }
                out.append("0};\n");
            },
            default => {},
        }
    }
    out.append("\n// the code of an error a callback threw (an Error whose code is the error's name), when it's one of\n// codes (they end with 0); else 0\nstatic inline uint32_t vn_code_of(napi_env env, napi_value e, const uint32_t *codes) {\n    napi_value c = NULL;\n    napi_valuetype t = napi_undefined;\n    char name[128];\n    size_t n = 0;\n    napi_typeof(env, e, &t);\n    if (t != napi_object || napi_get_named_property(env, e, \"code\", &c) != napi_ok) {\n        return 0;\n    }\n    napi_typeof(env, c, &t);\n    if (t != napi_string || napi_get_value_string_utf8(env, c, name, sizeof name, &n) != napi_ok) {\n        return 0;\n    }\n    for (; *codes; codes++) {\n        if (strcmp(vn_error_name(*codes), name) == 0) {\n            return *codes;\n        }\n    }\n    return 0;\n}\n\n// voltError(name): the Error a Volt function throws for that error (a callback throws one to give\n// Volt the error)\nstatic napi_value vn_volt_error(napi_env env, napi_callback_info info) {\n    size_t argc = 1, len = 0;\n    napi_value argv[1];\n    char *name = NULL;\n    char msg[160];\n    if (napi_get_cb_info(env, info, &argc, argv, NULL, NULL) != napi_ok || !vn_utf8(env, argv[0], &name, &len)) {\n        return NULL;\n    }\n    for (const uint32_t *c = vn_codes_all; *c; c++) {\n        if (strcmp(vn_error_name(*c), name) == 0) {\n            free(name);\n            return vn_code_error(env, *c);\n        }\n    }\n    snprintf(msg, sizeof msg, \"no error is named %.100s\", name);\n    free(name);\n    vn_throw(env, msg);\n    return NULL;\n}\n\n// ---------- calls back into JavaScript ----------\n\n// what a callback (or a trait fn a JavaScript object implements) threw while Volt called it: kept,\n// Volt gets a stand-in, and the Volt call it happened in throws it once it's back (an exception\n// never unwinds through Volt). Callbacks run on the JS thread that made the call\nstatic _Thread_local napi_value vn_thrown;\n\nstatic inline napi_value vn_null(napi_env env) {\n    napi_value v = NULL;\n    napi_get_null(env, &v);\n    return v;\n}\n\n// the exception pending (cleared), or an Error saying the call failed\nstatic inline napi_value vn_caught(napi_env env) {\n    napi_value e = NULL, msg = NULL;\n    bool pending = false;\n    napi_is_exception_pending(env, &pending);\n    if (pending) {\n        napi_get_and_clear_last_exception(env, &e);\n    }\n    if (!e) {\n        napi_create_string_utf8(env, \"a call from Volt into JavaScript failed\", NAPI_AUTO_LENGTH, &msg);\n        napi_create_error(env, NULL, msg, &e);\n    }\n    return e;\n}\n\n// keeps e (the first one) for the Volt call it happened in\nstatic inline void vn_keep(napi_env env, napi_escapable_handle_scope scope, napi_value e) {\n    if (!vn_thrown) {\n        napi_escape_handle(env, scope, e, &vn_thrown);\n    }\n}\n\n// a Volt call's error: what a callback threw, when that's why, else the error's own\nstatic inline void vn_throw_err(napi_env env, uint32_t code, napi_value thrown) {\n    if (thrown) {\n        napi_throw(env, thrown);\n    } else {\n        vn_throw_code(env, code);\n    }\n}\n\n// a callback that has to give Volt a handle threw: there's nothing to give, so the program stops, as\n// a Volt panic does\nstatic inline void vn_fatal(napi_env env, napi_value e, const char *what) {\n    char buf[512];\n    size_t n = 0;\n    napi_value s = NULL;\n    buf[0] = 0;\n    if (napi_coerce_to_string(env, e, &s) == napi_ok) {\n        napi_get_value_string_utf8(env, s, buf, sizeof buf, &n);\n    }\n    fprintf(stderr, \"panic: %s: %s\\n\", what, buf);\n    exit(101);\n}\n\nstatic inline int vn_call(napi_env env, napi_value f, size_t argc, const napi_value *argv, napi_value *ret) {\n    napi_value undef = NULL;\n    napi_get_undefined(env, &undef);\n    return napi_call_function(env, undef, f, argc, argv, ret) == napi_ok;\n}\n\nstatic inline int vn_call_method(napi_env env, napi_value o, const char *name, size_t argc, const napi_value *argv, napi_value *ret) {\n    napi_value f = NULL;\n    napi_valuetype t = napi_undefined;\n    char msg[160];\n    if (napi_get_named_property(env, o, name, &f) != napi_ok) {\n        return 0;\n    }\n    napi_typeof(env, f, &t);\n    if (t != napi_function) {\n        snprintf(msg, sizeof msg, \"the object has no %s()\", name);\n        return vn_throw(env, msg);\n    }\n    return napi_call_function(env, o, f, argc, argv, ret) == napi_ok;\n}\n\n// the bytes of a str or cstr a callback gives Volt: kept until the next one on this thread\n// ponytail: Volt reads it before the callback runs again; hold more if a fn keeps two\nstatic _Thread_local char *vn_kept;\n\nstatic inline int vn_cstr_kept(napi_env env, napi_value v, const char **out) {\n    char *buf = NULL;\n    if (!vn_cstr(env, v, out, &buf)) {\n        free(buf);\n        return 0;\n    }\n    free(vn_kept);\n    vn_kept = buf;\n    return 1;\n}\n\n// what an export fn's call takes over (class instances given up, Volt's trait values given back):\n// each checked as it's added (open, owned, there once), then all given at once, when nothing can\n// fail any more\nstruct vn_give {\n    napi_value v;\n    void *p;\n    int box; // Volt's trait value: its box is freed (the call has its object)\n};\n\nstruct vn_gives {\n    struct vn_give *at;\n    size_t n, cap;\n};\n\n// ponytail: the twice check is O(n^2); a set if calls give thousands\nstatic inline int vn_add_give(napi_env env, struct vn_gives *g, napi_value v, void *p, int box) {\n    for (size_t i = 0; i < g->n; i++) {\n        if (g->at[i].p == p) {\n            return vn_throw(env, \"the same object is given twice\");\n        }\n    }\n    if (g->n == g->cap) {\n        size_t cap = g->cap ? g->cap * 2 : 4;\n        struct vn_give *at = realloc(g->at, cap * sizeof *at);\n        if (!at) {\n            return vn_throw(env, \"out of memory\");\n        }\n        g->at = at;\n        g->cap = cap;\n    }\n    g->at[g->n].v = v;\n    g->at[g->n].p = p;\n    g->at[g->n].box = box;\n    g->n++;\n    return 1;\n}\n\nstatic inline void vn_give_all(napi_env env, struct vn_gives *g) {\n    for (size_t i = 0; i < g->n; i++) {\n        vn_detach(env, g->at[i].v);\n        if (g->at[i].box) {\n            free(g->at[i].p);\n        }\n    }\n}\n\n// an array of class instances as their handles: lent for the call, or given up (g)\nstatic inline int vn_handles(napi_env env, napi_value v, const napi_type_tag *tags, const char *what, struct vn_gives *g, void ***out, uint32_t *n) {\n    if (!vn_array(env, v, n)) {\n        return 0;\n    }\n    *out = calloc(*n ? *n : 1, sizeof **out);\n    if (!*out) {\n        return vn_throw(env, \"out of memory\");\n    }\n    for (uint32_t i = 0; i < *n; i++) {\n        napi_value e = NULL;\n        napi_get_element(env, v, i, &e);\n        if (!vn_unwrap(env, e, tags, g != NULL, &(*out)[i], what) || (g && !vn_add_give(env, g, e, (*out)[i], 0))) {\n            return 0;\n        }\n    }\n    return 1;\n}\n");
    if (this.uses_str) {
        out.append("\nstatic inline int vn_str_kept(napi_env env, napi_value v, volt_str *out) {\n    char *buf = NULL;\n    if (!vn_str(env, v, out, &buf)) {\n        free(buf);\n        return 0;\n    }\n    free(vn_kept);\n    vn_kept = buf;\n    return 1;\n}\n\n// an array of strings as strs (each one's bytes its own, freed with vn_free_strs)\nstatic inline int vn_strs(napi_env env, napi_value v, volt_str **out, uint32_t *n) {\n    if (!vn_array(env, v, n)) {\n        return 0;\n    }\n    *out = calloc(*n ? *n : 1, sizeof **out);\n    if (!*out) {\n        return vn_throw(env, \"out of memory\");\n    }\n    for (uint32_t i = 0; i < *n; i++) {\n        napi_value e = NULL;\n        char *buf = NULL;\n        napi_get_element(env, v, i, &e);\n        if (!vn_str(env, e, &(*out)[i], &buf)) {\n            free(buf);\n            return 0;\n        }\n    }\n    return 1;\n}\n\nstatic inline void vn_free_strs(volt_str *s, uint32_t n) {\n    if (s) {\n        for (uint32_t i = 0; i < n; i++) {\n            free((void *)s[i].ptr);\n        }\n        free(s);\n    }\n}\n");
    }
    if (this.texts.len > 0) {
        out.append("\n// owned text Volt gave out: a string, then freed\nstatic inline napi_value vn_take_text(napi_env env, volt_text t) {\n    napi_value v = vn_from_str(env, t.ptr, t.len);\n    volt_text_free(t);\n    return v;\n}\n\n// a string as owned text for Volt (what a callback gives back), which frees it\nstatic inline int vn_text(napi_env env, napi_value v, volt_text *out) {\n    char *buf = NULL;\n    size_t len = 0;\n    if (!vn_utf8(env, v, &buf, &len)) {\n        free(buf);\n        return 0;\n    }\n    out->ptr = (const uint8_t *)buf;\n    out->len = len;\n    out->owner = buf;\n    out->drop = free;\n    return 1;\n}\n\n// what frees the empty text a callback that threw gives Volt: nothing\nstatic inline void vn_no_drop(void *owner) {\n    (void)owner;\n}\n");
    }
    if (this.traits.len > 0) {
        out.append("\n// ---------- traits ----------\n\n// a trait's object as C passes it: its table, the object, and what frees it (null: it's lent)\nstruct vn_tobj {\n    const void *vt;\n    void *self;\n    void (*drop)(void *self);\n};\n\n// a JavaScript object Volt calls a trait's fns on: lent for a call (v), or given to Volt (a\n// reference, until Volt drops it)\nstruct vn_obj {\n    napi_env env;\n    napi_value v;\n    napi_ref ref;\n};\n\nstatic inline napi_value vn_obj_value(struct vn_obj *o) {\n    napi_value v = o->v;\n    if (!v) {\n        napi_get_reference_value(o->env, o->ref, &v);\n    }\n    return v;\n}\n\n// Volt drops a JavaScript object it was given: its [Symbol.dispose]() or close() runs, when it has one\nstatic inline void vn_obj_drop(void *self) {\n    struct vn_obj *o = self;\n    napi_env env = o->env;\n    napi_escapable_handle_scope scope = NULL;\n    napi_value v = NULL, g = NULL, sym = NULL, f = NULL, ret = NULL;\n    napi_valuetype t = napi_undefined;\n    napi_open_escapable_handle_scope(env, &scope);\n    v = vn_obj_value(o);\n    napi_get_global(env, &g);\n    napi_get_named_property(env, g, \"Symbol\", &sym);\n    napi_get_named_property(env, sym, \"dispose\", &sym);\n    napi_typeof(env, sym, &t);\n    if (t == napi_symbol) {\n        napi_get_property(env, v, sym, &f);\n    }\n    t = napi_undefined;\n    if (f) {\n        napi_typeof(env, f, &t);\n    }\n    if (t != napi_function) {\n        napi_get_named_property(env, v, \"close\", &f);\n        napi_typeof(env, f, &t);\n    }\n    if (t == napi_function && napi_call_function(env, v, f, 0, NULL, &ret) != napi_ok) {\n        vn_keep(env, scope, vn_caught(env));\n    }\n    napi_close_escapable_handle_scope(env, scope);\n    napi_delete_reference(env, o->ref);\n    free(o);\n}\n\n// a JavaScript object given to Volt: held until Volt drops it\nstatic inline struct vn_obj *vn_obj_new(napi_env env, napi_value v) {\n    struct vn_obj *o = malloc(sizeof *o);\n    if (!o) {\n        fprintf(stderr, \"panic: out of memory\\n\");\n        exit(101);\n    }\n    o->env = env;\n    o->v = NULL;\n    napi_create_reference(env, v, 1, &o->ref);\n    return o;\n}\n\n// a trait's object from v: Volt's own (tags: an instance of its class; given, the call takes it\n// over), or a JavaScript object with the trait's fns (their names end with NULL), called through vt:\n// lent for the call, or (no lent) given, which the call's give makes\nstatic inline int vn_get_obj(napi_env env, napi_value v, const napi_type_tag *tags, const void *vt, const char *const *fns, const char *what, struct vn_obj *lent, struct vn_gives *g, void *out) {\n    struct vn_tobj *o = out;\n    napi_valuetype t = napi_undefined;\n    bool is = false;\n    char msg[200];\n    napi_check_object_type_tag(env, v, &tags[0], &is);\n    if (is) {\n        struct vn_tobj *box = NULL;\n        if (napi_unwrap(env, v, (void **)&box) != napi_ok || !box) {\n            snprintf(msg, sizeof msg, \"this volt_%s is closed\", what);\n            return vn_throw(env, msg);\n        }\n        *o = *box;\n        if (lent) {\n            o->drop = NULL;\n            return vn_busy_add(env, box);\n        }\n        return vn_busy_check(env, box, what) && vn_add_give(env, g, v, box, 1);\n    }\n    napi_typeof(env, v, &t);\n    if (t == napi_object || t == napi_function) {\n        for (; *fns; fns++) {\n            napi_value f = NULL;\n            napi_valuetype ft = napi_undefined;\n            if (napi_get_named_property(env, v, *fns, &f) != napi_ok) {\n                return 0;\n            }\n            napi_typeof(env, f, &ft);\n            if (ft != napi_function) {\n                snprintf(msg, sizeof msg, \"expected a %s: the object has no %s()\", what, *fns);\n                return vn_throw(env, msg);\n            }\n        }\n        o->vt = vt;\n        if (lent) {\n            lent->env = env;\n            lent->v = v;\n            lent->ref = NULL;\n            o->self = lent;\n            o->drop = NULL;\n        } else {\n            o->self = NULL;\n            o->drop = vn_obj_drop;\n        }\n        return 1;\n    }\n    snprintf(msg, sizeof msg, \"expected a %s (an object with its methods)\", what);\n    return vn_throw(env, msg);\n}\n\nstatic void vn_finalize_obj(napi_env env, void *data, void *hint) {\n    struct vn_tobj *o = data;\n    (void)env;\n    (void)hint;\n    if (o->drop) {\n        o->drop(o->self);\n    }\n    free(o);\n}\n\n// frees Volt's trait value now (it's freed when the object is collected otherwise); data: the tags\nstatic napi_value vn_close_obj(napi_env env, napi_callback_info info) {\n    napi_value self = NULL, undef = NULL;\n    void *data = NULL, *o = NULL;\n    bool is = false;\n    napi_get_cb_info(env, info, NULL, NULL, &self, &data);\n    if (napi_check_object_type_tag(env, self, data, &is) == napi_ok && is && napi_unwrap(env, self, &o) == napi_ok && o) {\n        if (!vn_busy_check(env, o, \"value\")) {\n            return NULL;\n        }\n        napi_remove_wrap(env, self, &o);\n        vn_finalize_obj(env, o, NULL);\n    }\n    napi_get_undefined(env, &undef);\n    return undef;\n}\n\nstatic inline napi_value vn_obj_ctor(napi_env env, napi_callback_info info, const napi_type_tag *tags, const char *what) {\n    size_t argc = 1;\n    napi_value argv[1], self = NULL;\n    napi_valuetype t0 = napi_undefined;\n    void *o = NULL;\n    char msg[160];\n    if (napi_get_cb_info(env, info, &argc, argv, &self, NULL) != napi_ok) {\n        return NULL;\n    }\n    if (argc >= 1) {\n        napi_typeof(env, argv[0], &t0);\n    }\n    if (t0 != napi_external) {\n        snprintf(msg, sizeof msg, \"volt_%s is made by the library's functions\", what);\n        napi_throw_type_error(env, NULL, msg);\n        return NULL;\n    }\n    napi_get_value_external(env, argv[0], &o);\n    napi_wrap(env, self, o, vn_finalize_obj, NULL, NULL);\n    napi_type_tag_object(env, self, &tags[0]);\n    return self;\n}\n\n// an instance of class cls holding o, a trait's object Volt gave out (freed with it)\nstatic inline napi_value vn_wrap_obj(napi_env env, napi_ref cls, const void *o) {\n    napi_value c = NULL, ext = NULL, obj = NULL;\n    struct vn_tobj *box = malloc(sizeof *box);\n    if (!box) {\n        const struct vn_tobj *x = o;\n        if (x->drop) {\n            x->drop(x->self);\n        }\n        vn_throw(env, \"out of memory\");\n        return NULL;\n    }\n    memcpy(box, o, sizeof *box);\n    napi_get_reference_value(env, cls, &c);\n    napi_create_external(env, box, NULL, NULL, &ext);\n    napi_new_instance(env, c, 1, &ext, &obj);\n    return obj;\n}\n");
    }
    if (this.closures_out.len > 0) {
        out.append("\n// ---------- closures Volt gives out ----------\n\n// a closure Volt gave out, held by the JavaScript function that calls it: call, self and drop (as\n// the closure's struct has them), and whether it's still there\nstruct vn_fn {\n    void (*call)(void);\n    void *self;\n    void (*drop)(void *self);\n    int live;\n};\n\nstatic const napi_type_tag vn_tag_fn = {0x766f6c74666e0001ULL, 0x6e6f64652d666e00ULL};\n\nstatic inline void vn_fn_free(struct vn_fn *b) {\n    if (b->live) {\n        b->live = 0;\n        if (b->drop) {\n            b->drop(b->self);\n        }\n    }\n}\n\nstatic void vn_finalize_fn(napi_env env, void *data, void *hint) {\n    (void)env;\n    (void)hint;\n    vn_fn_free(data);\n    free(data);\n}\n\n// frees the closure now (it's freed when the function is collected otherwise)\nstatic napi_value vn_close_fn(napi_env env, napi_callback_info info) {\n    napi_value self = NULL, undef = NULL;\n    void *b = NULL;\n    bool is = false;\n    napi_get_cb_info(env, info, NULL, NULL, &self, NULL);\n    if (napi_check_object_type_tag(env, self, &vn_tag_fn, &is) == napi_ok && is && napi_unwrap(env, self, &b) == napi_ok && b) {\n        if (!vn_busy_check(env, b, \"function\")) {\n            return NULL;\n        }\n        vn_fn_free(b);\n    }\n    napi_get_undefined(env, &undef);\n    return undef;\n}\n\n// obj[Symbol.dispose] = close, where there's a Symbol.dispose (for `using`)\nstatic inline void vn_set_dispose(napi_env env, napi_value obj, napi_value close) {\n    napi_value g = NULL, sym = NULL, d = NULL;\n    napi_valuetype t = napi_undefined;\n    napi_get_global(env, &g);\n    napi_get_named_property(env, g, \"Symbol\", &sym);\n    napi_get_named_property(env, sym, \"dispose\", &d);\n    napi_typeof(env, d, &t);\n    if (t == napi_symbol) {\n        napi_set_property(env, obj, d, close);\n    }\n}\n\n// a JavaScript function calling closure c (the struct a Volt function gave out), with close()\nstatic inline napi_value vn_make_fn(napi_env env, const void *c, napi_callback call) {\n    napi_value f = NULL, close = NULL;\n    struct vn_fn *b = malloc(sizeof *b);\n    if (!b) {\n        const struct vn_fn *x = c;\n        if (x->drop) {\n            x->drop(x->self);\n        }\n        vn_throw(env, \"out of memory\");\n        return NULL;\n    }\n    memcpy(b, c, offsetof(struct vn_fn, live));\n    b->live = 1;\n    napi_create_function(env, NULL, 0, call, b, &f);\n    napi_wrap(env, f, b, vn_finalize_fn, NULL, NULL);\n    napi_type_tag_object(env, f, &vn_tag_fn);\n    napi_create_function(env, \"close\", NAPI_AUTO_LENGTH, vn_close_fn, NULL, &close);\n    napi_set_named_property(env, f, \"close\", close);\n    vn_set_dispose(env, f, close);\n    return f;\n}\n\nstatic inline int vn_fn_live(napi_env env, void *data, void **out) {\n    struct vn_fn *b = data;\n    if (!b || !b->live) {\n        return vn_throw(env, \"this function is closed\");\n    }\n    *out = b;\n    return vn_busy_add(env, b);\n}\n");
    }
    // structs: to and from plain objects
    for (s&) in this.structs.items() {
        if (!this.node_simple(this.c.t.intern(tyk::STRUCT(*s)))) {
            continue;
        }
        val sn = this.node_sname(*s);
        val cn = this.c_named(this.c.si(*s).name, false);
        out.append(fmt3("\nstatic inline int vn_get_{}(napi_env env, napi_value v, {} *out) {{\n    napi_valuetype t = napi_undefined;\n    napi_typeof(env, v, &t);\n    if (t != napi_object) {{\n        return vn_throw(env, \"expected a {} object\");\n    }}\n", copy sn, copy cn, copy sn).as_str());
        for (f&) in this.c.si(*s).fields.items() {
            out.append(fmt2("    {{\n        napi_value f;\n        napi_get_named_property(env, v, \"{}\", &f);\n        {}\n    }}\n", S(f.name), this.node_get_simple(f.ty, "f", fmt("out->{}", S(f.name)).as_str())).as_str());
        }
        out.append("    return 1;\nfail:\n    return 0;\n}\n");
        out.append(fmt2("\nstatic inline void vn_set_{}(napi_env env, napi_value v, const {} *in) {{\n", copy sn, copy cn).as_str());
        for (f&) in this.c.si(*s).fields.items() {
            out.append(fmt2("    napi_set_named_property(env, v, \"{}\", {});\n", S(f.name), this.node_put_simple(f.ty, fmt("in->{}", S(f.name)).as_str())).as_str());
        }
        out.append("}\n");
        out.append(fmt3("\nstatic inline napi_value vn_new_{}(napi_env env, const {} *in) {{\n    napi_value v = NULL;\n    napi_create_object(env, &v);\n    vn_set_{}(env, v, in);\n    return v;\n}}\n", copy sn, copy cn, copy sn).as_str());
    }
    // classes: a JS class per export struct, owning its handle (or lent it by Volt, for a callback)
    for (s&) in this.handles.items() {
        val sn = this.node_sname(*s);
        val cn = this.handle_c(*s, false);
        out.append(fmt4("\n// export struct {}\nstatic napi_ref vn_class_{};\nstatic const napi_type_tag vn_tags_{}[2] = {};\n", S(this.c.si(*s).name), copy sn, copy sn, this.node_tags(sn.as_str())).as_str());
        out.append(fmt2("\nstatic void vn_finalize_{}(napi_env env, void *data, void *hint) {{\n    (void)env;\n    (void)hint;\n    {}((void *)data);\n}}\n", copy sn, this.free_name(*s)).as_str());
        out.append(fmt3("\n// an instance owning handle h\nstatic napi_value vn_wrap_{}(napi_env env, {}h) {{\n    napi_value cls = NULL, ext = NULL, obj = NULL;\n    napi_get_reference_value(env, vn_class_{}, &cls);\n    napi_create_external(env, h, NULL, NULL, &ext);\n    napi_new_instance(env, cls, 1, &ext, &obj);\n    return obj;\n}}\n", copy sn, spaced(copy cn), copy sn).as_str());
        out.append(fmt3("\n// an instance Volt lends handle h to (for a callback): it never frees it, and lets go of it when\n// the callback returns\nstatic inline napi_value vn_lend_{}(napi_env env, {}h) {{\n    napi_value cls = NULL, args[2], obj = NULL;\n    napi_get_reference_value(env, vn_class_{}, &cls);\n    napi_create_external(env, h, NULL, NULL, &args[0]);\n    napi_get_boolean(env, true, &args[1]);\n    napi_new_instance(env, cls, 2, args, &obj);\n    return obj;\n}}\n", copy sn, spaced(copy cn), copy sn).as_str());
        out.append(fmt3("\n// frees the handle now (it's freed when the object is collected otherwise; not while it's lent to a\n// call that's running); one Volt lent is let go of\nstatic napi_value vn_close_{}(napi_env env, napi_callback_info info) {{\n    napi_value self = NULL, undef = NULL;\n    void *h = NULL;\n    bool own = false, lent = false;\n    napi_get_cb_info(env, info, NULL, NULL, &self, NULL);\n    napi_check_object_type_tag(env, self, &vn_tags_{}[0], &own);\n    napi_check_object_type_tag(env, self, &vn_tags_{}[1], &lent);\n", copy sn, copy sn, copy sn).as_str());
        out.append(fmt2("    if ((own || lent) && napi_unwrap(env, self, &h) == napi_ok && h) {\n        if (own && !vn_busy_check(env, h, \"{}\")) {\n            return NULL;\n        }\n        napi_remove_wrap(env, self, &h);\n        if (own) {\n            {}(h);\n        }\n    }\n    napi_get_undefined(env, &undef);\n    return undef;\n}\n", copy sn, this.free_name(*s)).as_str());
    }
    // callbacks: the C function a Volt closure parameter calls, which calls the JS function
    out.append("\n// a JS function passed for a callback (only used during the call)\nstruct vn_cb {\n    napi_env env;\n    napi_value fn;\n};\n");
    for (i) in 0..this.closures.len {
        if (!this.node_cb_used(@cast<u32>(i))) {
            continue;
        }
        var ps: std::vec<u32> = {};
        val r = this.fn_parts(*this.closures.at(i), &ps);
        var sig = fmt2("{}vn_cb{}(void *user", spaced(this.c_prim(r, false)), unum(@cast<u64>(i)));
        for (k) in 0..ps.len {
            sig.append(fmt2(", {}a{}", spaced(this.c_in(*ps.at(k), false)), unum(@cast<u64>(k))).as_str());
        }
        sig.push(')');
        val call = fmt("vn_call(env, c->fn, {}, argv, &ret)", unum(@cast<u64>(ps.len)));
        out.append((try this.node_upcall(copy sig, "    struct vn_cb *c = user;\n    napi_env env = c->env;\n", call.as_str(), &ps, r)).as_str());
    }
    // traits: the table Volt calls a JS object's methods through, and volt_T, a class of Volt's own
    // values that calls theirs
    for (k) in 0..this.traits.len {
        val t = *this.traits.at(k);
        val tr = this.short(t);
        val fns = this.fns_of(t);
        out.append(fmt4("\n// trait {}: any JS object with its methods, or volt_{}, Volt's own value\nstatic napi_ref vn_class_volt_{};\nstatic const napi_type_tag vn_tags_volt_{}[2] = ", this.c.ty_name(t), copy tr, copy tr, copy tr).as_str());
        out.append(fmt2("{};\nstatic const char *const vn_fns_{}[] = {{", this.node_tags(fmt("volt_{}", copy tr).as_str()), copy tr).as_str());
        for (f&) in fns.items() {
            out.append(fmt("\"{}\", ", S(f.name)).as_str());
        }
        out.append("NULL};\n");
        var table: std::string = {};
        for (f&) in fns.items() {
            val nm = fmt2("vn_up_{}_{}", copy tr, S(f.name));
            var sig = fmt2("{}{}(void *user", spaced(this.c_out(f.ret, false)), copy nm);
            for (q) in 0..f.params.len {
                sig.append(fmt2(", {}a{}", spaced(this.c_in(*f.params.at(q), false)), unum(@cast<u64>(q))).as_str());
            }
            sig.push(')');
            val call = fmt2("vn_call_method(env, vn_obj_value(c), \"{}\", {}, argv, &ret)", S(f.name), unum(@cast<u64>(f.params.len)));
            out.append((try this.node_upcall(copy sig, "    struct vn_obj *c = user;\n    napi_env env = c->env;\n", call.as_str(), &f.params, f.ret)).as_str());
            if (table.len() > 0) {
                table.append(", ");
            }
            table.append(nm.as_str());
        }
        out.append(fmt3("\nstatic const {} vn_vt_{} = {{{}}};\n", this.c_named(fmt("{}_vt", copy tr).as_str(), false), copy tr, copy table).as_str());
        out.append(fmt3("\nstatic napi_value vn_ctor_volt_{}(napi_env env, napi_callback_info info) {{\n    return vn_obj_ctor(env, info, vn_tags_volt_{}, \"{}\");\n}}\n", copy tr, copy tr, copy tr).as_str());
        val self_decl = fmt("    {} *p_self = NULL;\n", this.c_named(tr.as_str(), false));
        val self_get = fmt2("    if (!vn_unwrap(env, self, vn_tags_volt_{}, 0, (void **)&p_self, \"volt_{}\")) {\n        goto fail;\n    }\n", copy tr, copy tr);
        for (f&) in fns.items() {
            var names: std::vec<std::string> = {};
            for (q) in 0..f.params.len {
                put(&names, fmt("p_a{}", unum(@cast<u64>(q))));
            }
            try this.node_call(fmt2("vn_m_volt_{}_{}", copy tr, S(f.name)).as_str(), f.name, &f.params, &names, self_decl.as_str(), self_get.as_str(), fmt("p_self->vt->{}", S(f.name)).as_str(), "p_self->self", f.ret, &out);
        }
    }
    // closures Volt gives out: a JS function calls each
    for (i) in 0..this.closures.len {
        if (!has_u32(&this.closures_out, @cast<u32>(i))) {
            continue;
        }
        var ps: std::vec<u32> = {};
        val r = this.fn_parts(*this.closures.at(i), &ps);
        var names: std::vec<std::string> = {};
        for (k) in 0..ps.len {
            put(&names, fmt("p_a{}", unum(@cast<u64>(k))));
        }
        val self_decl = fmt("    {} *p_fn = NULL;\n", this.c_named(fmt("closure{}", unum(@cast<u64>(i))).as_str(), false));
        out.append(fmt("\n// {}, given out by Volt: a JS function calls it\n", this.c.ty_name(*this.closures.at(i))).as_str());
        try this.node_call(fmt("vn_call_closure{}", unum(@cast<u64>(i))).as_str(), "the function", &ps, &names, self_decl.as_str(), "    if (!vn_fn_live(env, data, (void **)&p_fn)) {\n        goto fail;\n    }\n", "p_fn->call", "p_fn->self", r, &out);
    }
    // the classes' constructors: a handle from C (an External, lent with a second argument), or the
    // class's new
    for (s&) in this.handles.items() {
        val sn = this.node_sname(*s);
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
        out.append(fmt2("\nstatic napi_value vn_ctor_{}(napi_env env, napi_callback_info info) {{\n    size_t argc = 2;\n    napi_value argv[2], self = NULL, made = NULL;\n    napi_valuetype t0 = napi_undefined;\n    void *h = NULL;\n    if (napi_get_cb_info(env, info, &argc, argv, &self, NULL) != napi_ok) {{\n        return NULL;\n    }}\n    if (argc >= 1) {{\n        napi_typeof(env, argv[0], &t0);\n    }}\n    if (t0 == napi_external) {{\n        napi_get_value_external(env, argv[0], &h);\n        if (argc >= 2) {{\n            // lent by Volt: never freed here\n            napi_wrap(env, self, h, NULL, NULL, NULL);\n            napi_type_tag_object(env, self, &vn_tags_{}[1]);\n            return self;\n        }}\n    }} else {{\n", copy sn, copy sn).as_str());
        if (mk) {
            // run new with the same arguments, then take its handle from the instance it made
            out.append(fmt("        made = vn_new_{}(env, info);\n        if (!made || napi_remove_wrap(env, made, &h) != napi_ok) {\n            return NULL;\n        }\n", copy sn).as_str());
        } else {
            out.append(fmt("        (void)made;\n        napi_throw_type_error(env, NULL, \"{} is made by the library's functions\");\n        return NULL;\n", copy sn).as_str());
        }
        out.append(fmt2("    }}\n    napi_wrap(env, self, h, vn_finalize_{}, NULL, NULL);\n    napi_type_tag_object(env, self, &vn_tags_{}[0]);\n    return self;\n}}\n", copy sn, copy sn).as_str());
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
    var nfree: usize = 1;
    for (e&) in ents.items() {
        if (e.free_of == null && this.class_of(e.f) == null) {
            nfree += 1;
        }
    }
    out.append("    napi_property_descriptor fns[] = {\n        {\"voltError\", NULL, vn_volt_error, NULL, NULL, NULL, napi_enumerable, NULL},\n");
    for (e&) in ents.items() {
        if (e.free_of != null || this.class_of(e.f) != null) {
            continue;
        }
        val n = S(this.c.fi(e.f).c_name);
        out.append(fmt2("        {{\"{}\", NULL, vn_f_{}, NULL, NULL, NULL, napi_enumerable, NULL}},\n", copy n, copy n).as_str());
    }
    out.append(fmt("    };\n    napi_define_properties(env, exports, {}, fns);\n", unum(@cast<u64>(nfree))).as_str());
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
            out.append(fmt3("            {{\"{}\", NULL, vn_f_{}, NULL, NULL, NULL, {}, NULL}},\n", S(m), S(this.c.fi(e.f).c_name), copy attr).as_str());
            nps += 1;
        }
        out.append(fmt4("        };\n        napi_value cls = NULL;\n        napi_define_class(env, \"{}\", NAPI_AUTO_LENGTH, vn_ctor_{}, NULL, {}, ps, &cls);\n        napi_create_reference(env, cls, 1, &vn_class_{});\n", copy sn, copy sn, unum(@cast<u64>(nps)), copy sn).as_str());
        out.append(fmt("        napi_set_named_property(env, exports, \"{}\", cls);\n    }\n", copy sn).as_str());
    }
    for (t&) in this.traits.items() {
        val tr = this.short(*t);
        out.append("    {\n        napi_property_descriptor ps[] = {\n");
        out.append(fmt("            {\"close\", NULL, vn_close_obj, NULL, NULL, NULL, napi_default_method, (void *)vn_tags_volt_{}},\n", copy tr).as_str());
        var nps: usize = 1;
        for (f&) in this.fns_of(*t).items() {
            out.append(fmt3("            {{\"{}\", NULL, vn_m_volt_{}_{}, NULL, NULL, NULL, napi_default_method, NULL}},\n", S(f.name), copy tr, S(f.name)).as_str());
            nps += 1;
        }
        out.append(fmt4("        };\n        napi_value cls = NULL;\n        napi_define_class(env, \"volt_{}\", NAPI_AUTO_LENGTH, vn_ctor_volt_{}, NULL, {}, ps, &cls);\n        napi_create_reference(env, cls, 1, &vn_class_volt_{});\n", copy tr, copy tr, unum(@cast<u64>(nps)), copy tr).as_str());
        out.append(fmt("        napi_set_named_property(env, exports, \"volt_{}\", cls);\n    }\n", copy tr).as_str());
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
    var classes: std::vec<std::string> = {};
    for (s&) in this.handles.items() {
        put(&classes, this.node_sname(*s));
    }
    for (t&) in this.traits.items() {
        put(&classes, fmt("volt_{}", this.short(*t)));
    }
    for (cn&) in classes.items() {
        out.append(fmt2("if (Symbol.dispose) {{\n    addon.{}.prototype[Symbol.dispose] = addon.{}.prototype.close;\n}}\n", copy *cn, copy *cn).as_str());
    }
    out.append("module.exports = addon;\n");
    return out;
}

// an array of e in TypeScript (a union or a function type in parentheses)
fn ts_array(e: std::string) -> std::string {
    var s = copy e;
    if (s.as_str().contains(" | ") || s.as_str().contains("=>")) {
        s = fmt("({})", copy s);
    }
    s.append("[]");
    return s;
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
        .SLICE(x) => { return ts_array(this.ts_ty(x, incoming)); },
        .LIST(x) => { return ts_array(this.ts_ty(this.list_elem(t), incoming)); },
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
        .TRAIT(i) => {
            // any object with the trait's methods goes in; Volt's own comes out
            val tr = this.short(this.trait_of(t));
            if (incoming) {
                return tr;
            }
            return fmt("volt_{}", copy tr);
        },
        .CLOSURE(i) => {
            // a function JS gives (a callback) takes what Volt gives, and the other way round for one
            // Volt gives out
            var ps: std::vec<u32> = {};
            val r = this.fn_parts(t, &ps);
            var s = S("(");
            for (k) in 0..ps.len {
                if (k > 0) {
                    s.append(", ");
                }
                var pt = this.ts_ty(*ps.at(k), !incoming);
                if (incoming) {
                    pt = this.ts_lent(*ps.at(k));
                }
                s.append(fmt2("a{}: {}", unum(@cast<u64>(k)), copy pt).as_str());
            }
            s.append(") => ");
            s.append(this.ts_ty(r, incoming).as_str());
            if (incoming) {
                return s;
            }
            return fmt("VoltFunction<{}>", copy s);
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
    return fmt3("{}/** {} */\n{}", S(indent_by), copy d, S(""));
}

// what JS gets for a callback's or a trait fn's parameter of type t (null for a T* Volt passes as none)
attach fn ts_lent(this: bind&, t: u32) -> std::string {
    var s = this.ts_ty(t, false);
    if (this.lent_handle(t) != null && !this.is_ref(t)) {
        s.append(" | null");
    }
    return s;
}

// a trait fn's methods in TypeScript: as a JS object implements it (vf: false; Volt gives the
// arguments) or as volt_T has it
attach fn ts_trait_fn(this: bind&, f: trait_fn&, vf: bool) -> std::string {
    var ps: std::string = {};
    for (q) in 0..f.params.len {
        if (q > 0) {
            ps.append(", ");
        }
        var pt = this.ts_ty(*f.params.at(q), true);
        if (!vf) {
            pt = this.ts_lent(*f.params.at(q));
        }
        ps.append(fmt2("a{}: {}", unum(@cast<u64>(q)), copy pt).as_str());
    }
    return fmt3("    {}({}): {};\n", S(f.name), copy ps, this.ts_ty(f.ret, !vf));
}

attach fn ts_text(this: bind&) -> std::string {
    val ents = this.entries();
    var out = fmt("// {}: generated by voltc bindings; TypeScript types for the Node-API addon\n", S(this.pkg));
    out.append("// (voltc bindings --lang node) and its loader (--lang js). An error a Volt function returns is\n// thrown as a VoltError: its code is the error's name. A callback throws voltError(name) to give Volt\n// that error.\n\n");
    out.append("export interface VoltError extends Error {\n    code: string;\n    errno: number;\n}\n\n/** the VoltError a Volt function throws for the error named name */\nexport declare function voltError(name: string): VoltError;\n");
    if (this.closures_out.len > 0) {
        out.append("\n/** a function Volt gave out: close() frees it now (or `using`); otherwise it's freed when collected */\nexport type VoltFunction<F> = F & { close(): void; [Symbol.dispose](): void };\n");
    }
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
        out.append(fmt2("}};\nexport type {} = {};\n", copy n, copy union).as_str());
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
    for (t&) in this.traits.items() {
        val tr = this.short(*t);
        out.append(fmt2("\n/** trait {}: any object with these methods, lent to Volt or given (Volt calls a given one's\n * [Symbol.dispose]() or close(), if it has one, when it's done with it) */\nexport interface {} {{\n", this.c.ty_name(*t), copy tr).as_str());
        for (f&) in this.fns_of(*t).items() {
            out.append(this.ts_trait_fn(f, false).as_str());
        }
        out.append(fmt3("}}\n\n/** a {} Volt made: close() frees it now (or `using`); otherwise it's freed when collected */\nexport declare class volt_{} implements {} {{\n    private constructor();\n", copy tr, copy tr, copy tr).as_str());
        for (f&) in this.fns_of(*t).items() {
            out.append(this.ts_trait_fn(f, true).as_str());
        }
        out.append("    close(): void;\n    [Symbol.dispose](): void;\n}\n");
    }
    for (s&) in this.handles.items() {
        val sn = this.node_sname(*s);
        out.append(fmt2("\n/** export struct {}: close() frees it now (or `using`); otherwise it's freed when collected */\nexport declare class {} {{\n", S(this.c.si(*s).name), copy sn).as_str());
        var made = false;
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
                made = true;
            } else {
                out.append(fmt3("    static {}({}): {};\n", S(m), this.ts_params(e.f, 0), this.ts_ty(info.ret, false)).as_str());
            }
        }
        if (!made) {
            // the library's functions make it
            out.append("    private constructor();\n");
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
// A Lua error longjmps, so a call into Volt converts every argument first (what that makes lives on
// Lua's stack, collected if a later one fails), then gives Volt what it takes, then calls it. A Lua
// function Volt calls (a callback, a Lua object's method) runs in a protected call: its first error
// is kept in the registry, Volt gets a stand-in, and the error is raised once the Volt call is back

// a metatable's name, quoted: "pkg.name"
attach fn lua_mt(this: bind&, name: str) -> std::string {
    return fmt2("\"{}.{}\"", S(this.pkg), S(name));
}

// how deep in arrays and slices C lvalue c is: its loops' variables are named after it
fn lua_depth(c: str) -> std::string {
    var n: u64 = 0;
    for (ch) in c {
        if (ch == '[') {
            n += 1;
        }
    }
    return unum(n);
}

// a C expression: the handle of export struct s in the userdata at idx, lent (how 1), given (2) or
// copied in for the call (3), marked in the call's table kp (see vl_mark)
attach fn lua_handle(this: bind&, s: u32, idx: str, kp: str, how: str, what: str) -> std::string {
    return fmt5("vl_handle_in(L, {}, {}, {}, {}, {})->h", S(idx), this.lua_mt(this.node_sname(s).as_str()), S(kp), S(how), S(what));
}

// the C function giving error set e's code for the error a Lua function names (see vl_error_of)
attach fn lua_code_fn(this: bind&, e: u32) -> std::string {
    if (e == ANYERR) {
        return S("vl_code_any");
    }
    return fmt("vl_code_{}", this.short(e));
}

// C statements reading the Lua value at stack index idx into C lvalue c, for a value that crosses as
// itself (what sits inside other types, and optionals of it); what (a C string expression) names the
// value in the error raised when it doesn't fit. What they push stays on the stack (memory for a
// slice) until the call is done
attach fn lua_get(this: bind&, t: u32, idx: str, c: str, what: str) -> std::string {
    match (this.shape_of(t) ?? shape::VOID) {
        .VOID => { return {}; },
        .BOOL => { return fmt3("{} = vl_bool(L, {}, {});", S(c), S(idx), S(what)); },
        .FLOAT(b) => { return fmt4("{} = ({})vl_num(L, {}, {});", S(c), this.c_prim(t, false), S(idx), S(what)); },
        .INT(k) => { return fmt4("{} = ({})vl_int(L, {}, {});", S(c), this.c_prim(t, false), S(idx), fmt2("{}, {}", lua_limits(k), S(what))); },
        .ENUM(e) => { return fmt4("{} = ({})vl_int(L, {}, {});", S(c), this.c_prim(t, false), S(idx), fmt2("{}, {}", lua_limits(this.c.ei(e).tag), S(what))); },
        .CODE => { return fmt3("{} = (uint32_t)vl_int(L, {}, 0, UINT32_MAX, {});", S(c), S(idx), S(what)); },
        .STRUCT(s) => { return fmt4("vl_get_{}(L, {}, &{}, {});", this.node_sname(s), S(idx), S(c), S(what)); },
        .STR => { return fmt4("{}.ptr = (const uint8_t *)vl_str(L, {}, &{}.len, {});", S(c), S(idx), S(c), S(what)); },
        .CSTR => { return fmt4("{} = lua_isnoneornil(L, {}) ? NULL : vl_str(L, {}, NULL, {});", S(c), S(idx), S(idx), S(what)); },
        .PTR(x) => {
            // nil is null, a handle is lent, anything else is a pointer from this library
            var p = fmt2("vl_pointer(L, {}, {})", S(idx), S(what));
            val h = this.struct_handle(x);
            if (h) {
                p = this.lua_handle(h, idx, "0", "1", what);
            }
            return fmt4("{} = NULL; if (!lua_isnoneornil(L, {})) {{ {} = {}; }", S(c), S(idx), S(c), move p);
        },
        .FN(i) => { return fmt4("{} = ({})vl_pointer(L, {}, {});", S(c), this.c_prim(t, false), S(idx), S(what)); },
        .ARRAY(elem, n) => {
            val d = lua_depth(c);
            var s = fmt5("{{ int t{} = lua_absindex(L, {}); (void)vl_seq(L, t{}, {}); for (size_t i{} = 0; ", copy d, S(idx), copy d, S(what), copy d);
            s.append(fmt5("i{} < {}; i{}++) {{ lua_geti(L, t{}, (lua_Integer)i{} + 1); ", copy d, unum(n), copy d, copy d, copy d).as_str());
            val el = this.lua_get(elem, fmt("e{}", copy d).as_str(), fmt2("{}[i{}]", S(c), copy d).as_str(), what);
            s.append(fmt3("int e{} = lua_gettop(L); {} lua_remove(L, e{}); }} }", copy d, move el, copy d).as_str());
            return s;
        },
        .SLICE(x) => { return this.lua_seq(x, idx, c, what, "0", "1"); },
        .OPT(x) => {
            var s = fmt4("memset(&{}, 0, sizeof {}); if (!lua_isnoneornil(L, {})) {{ {}.has = true; ", S(c), S(c), S(idx), S(c));
            s.append(fmt("{} }", this.lua_get(x, idx, fmt("{}.value", S(c)).as_str(), what)).as_str());
            return s;
        },
        .RESULT(e, x) => {
            // an error from Volt is its code, anything else the value
            var s = fmt4("if (vl_is_error(L, {})) {{ {}.error = {}(L, {}, ", S(idx), S(c), this.lua_code_fn(e), S(idx));
            s.append(fmt3("{}); }} else {{ {} {}.error = 0; }", S(what), this.lua_get(x, idx, fmt("{}.value", S(c)).as_str(), what), S(c)).as_str());
            return s;
        },
        default => { return fmt("luaL_error(L, \"%s: unsupported\", {});", S(what)); },
    }
}

// statements reading the sequence at idx into C slice c, each element as e's view (see lua_elem),
// into memory left on the stack
attach fn lua_seq(this: bind&, e: u32, idx: str, c: str, what: str, kp: str, how: str) -> std::string {
    val d = lua_depth(c);
    val el = this.lua_elem(e, fmt("e{}", copy d).as_str(), fmt2("{}.ptr[i{}]", S(c), copy d).as_str(), what, kp, how);
    var s = fmt5("{{ int t{} = lua_absindex(L, {}); {}.len = vl_seq(L, t{}, {}); ", copy d, S(idx), S(c), copy d, S(what));
    s.append(fmt4("{}.ptr = vl_buffer(L, sizeof *{}.ptr, {}.len); for (size_t i{} = 0; ", S(c), S(c), S(c), copy d).as_str());
    s.append(fmt5("i{} < {}.len; i{}++) {{ lua_geti(L, t{}, (lua_Integer)i{} + 1); ", copy d, S(c), copy d, copy d, copy d).as_str());
    s.append(fmt3("int e{} = lua_gettop(L); {} lua_remove(L, e{}); }} }", copy d, move el, copy d).as_str());
    return s;
}

// statements reading the sequence element at idx into C lvalue c, as element type e's view (see
// view_of): text is a str (kept in the call's table kp), a handle is lent (how 1), given (2) or
// copied in for the call (3)
attach fn lua_elem(this: bind&, e: u32, idx: str, c: str, what: str, kp: str, how: str) -> std::string {
    val h = this.handle_of(e);
    if (h) {
        return fmt2("{} = {};", S(c), this.lua_handle(h, idx, kp, how, what));
    }
    var s = this.lua_get(this.view_of(e), idx, c, what);
    if (this.view_of(e) == STR && kp != "0") {
        s.append(fmt3(" vl_mark(L, {}, {}, 1, {});", S(kp), S(idx), S(what)).as_str());
    }
    return s;
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

// a C statement pushing C value c of type t, a value that crosses as itself: a str is copied, a
// pointer is a light userdata (nil for null), an array or a slice a new sequence, E!T its value or
// the error
attach fn lua_push(this: bind&, t: u32, c: str) -> std::string {
    match (this.shape_of(t) ?? shape::VOID) {
        .BOOL => { return fmt("lua_pushboolean(L, {});", S(c)); },
        .FLOAT(b) => { return fmt("lua_pushnumber(L, (lua_Number)({}));", S(c)); },
        .STRUCT(s) => { return fmt2("vl_new_{}(L, &{});", this.node_sname(s), S(c)); },
        .STR => { return fmt2("lua_pushlstring(L, (const char *){}.ptr, {}.len);", S(c), S(c)); },
        .CSTR => { return fmt2("if ({}) {{ lua_pushstring(L, {}); }} else {{ lua_pushnil(L); }}", S(c), S(c)); },
        .PTR(x) => { return fmt2("if ({}) {{ lua_pushlightuserdata(L, (void *){}); }} else {{ lua_pushnil(L); }}", S(c), S(c)); },
        .FN(i) => { return fmt2("if ({}) {{ lua_pushlightuserdata(L, (void *){}); }} else {{ lua_pushnil(L); }}", S(c), S(c)); },
        .ARRAY(elem, n) => {
            val d = lua_depth(c);
            val el = this.lua_push(elem, fmt2("{}[i{}]", S(c), copy d).as_str());
            var s = fmt3("lua_createtable(L, {}, 0); for (size_t i{} = 0; i{} < ", unum(n), copy d, copy d);
            s.append(fmt4("{}; i{}++) {{ {} lua_seti(L, -2, (lua_Integer)i{} + 1); }", unum(n), copy d, move el, copy d).as_str());
            return s;
        },
        .SLICE(x) => {
            val el = this.lua_push(x, fmt2("{}.ptr[i{}]", S(c), lua_depth(c)).as_str());
            return this.lua_seq_out(x, c, move el);
        },
        .OPT(x) => { return fmt2("if ({}.has) {{ {} }} else {{ lua_pushnil(L); }}", S(c), this.lua_push(x, fmt("{}.value", S(c)).as_str())); },
        .RESULT(e, x) => {
            var ok = this.lua_push(x, fmt("{}.value", S(c)).as_str());
            if (x == VOID) {
                ok = S("lua_pushboolean(L, 1);");
            }
            return fmt3("if ({}.error != 0) {{ vl_push_error(L, {}.error); }} else {{ {} }", S(c), S(c), move ok);
        },
        default => { return fmt("lua_pushinteger(L, (lua_Integer)({}));", S(c)); },
    }
}

// statements pushing a new sequence of the elements of C slice or list r (of x's; el pushes element
// r.ptr[iN]), with its n field when they're optionals (nil for none, as table.pack gives)
attach fn lua_seq_out(this: bind&, x: u32, r: str, el: std::string) -> std::string {
    val d = lua_depth(r);
    var s = fmt3("lua_createtable(L, {}.len < INT_MAX ? (int){}.len : 0, 0); for (size_t i{} = 0; ", S(r), S(r), copy d);
    s.append(fmt5("i{} < {}.len; i{}++) {{ {} lua_seti(L, -2, (lua_Integer)i{} + 1); }", copy d, S(r), copy d, move el, copy d).as_str());
    match (*this.c.t.get(x)) {
        .OPT(v) => { s.append(fmt(" lua_pushinteger(L, (lua_Integer){}.len); lua_setfield(L, -2, \"n\");", S(r)).as_str()); },
        default => {},
    }
    return s;
}

// one argument of a call into Volt: its C locals (decl), the statements that fill them from the Lua
// argument (get), what the call passes (pass), and what writes Volt's changes back into Lua tables
// (after)
struct lua_arg {
    decl: std::string = {};
    get: std::string = {};
    pass: std::string = {};
    after: std::string = {};
}

// does a parameter of type t need its call's table (see vl_mark): it gives Volt something, or a
// sequence of strings or handles is held for the call
attach fn lua_keeps(this: bind&, t: u32) -> bool {
    match (this.shape_of(t) ?? shape::VOID) {
        .HANDLE(h) => { return true; },
        .TRAIT(i) => { return !this.is_ref(t); },
        .OPT(x) => { return this.handle_of(x) != null; },
        .LIST(x) => { return this.lua_keeps(this.in_ty(t)); },
        .SLICE(x) => { return x == STR || this.lent_handle(x) != null; },
        default => { return false; },
    }
}

// fills a for C parameter c of type t from the Lua argument at idx; kp is the call's table (keep, or
// 0 when it has none)
attach fn lua_in(this: bind&, t: u32, idx: str, c: str, what: str, kp: str, a: lua_arg&) -> void {
    a.pass = S(c);
    val h = this.lent_handle(t);
    if (h) {
        a.decl = fmt2("{}{};", spaced(this.handle_c(h, false)), S(c));
        a.get = fmt2("{} = {};", S(c), this.lua_handle(h, idx, kp, "1", what));
        return;
    }
    match (this.shape_of(t) ?? shape::VOID) {
        .HANDLE(s) => {
            // given to Volt: its userdata is closed once every argument has converted
            a.decl = fmt2("{}{};", spaced(this.handle_c(s, false)), S(c));
            a.get = fmt2("{} = {};", S(c), this.lua_handle(s, idx, kp, "2", what));
            return;
        },
        .OPT(x) => {
            val oh = this.handle_of(x);
            if (oh) {
                // nil, or an export struct given to Volt
                a.decl = fmt2("{}{} = NULL;", spaced(this.handle_c(oh, false)), S(c));
                a.get = fmt3("if (!lua_isnoneornil(L, {})) {{ {} = {}; }", S(idx), S(c), this.lua_handle(oh, idx, kp, "2", what));
                return;
            }
        },
        .TRAIT(i) => {
            // Volt's own object, or a Lua object with the trait's methods: lent from the stack, or
            // given (held until Volt drops it)
            a.decl = fmt2("{} {};", this.c_prim(t, false), S(c));
            var o = S("NULL");
            if (this.is_ref(t)) {
                a.decl.append(fmt2(" vl_lua {}_o = {{L, {}, LUA_NOREF};", S(c), S(idx)).as_str());
                o = fmt("&{}_o", S(c));
            }
            a.get = fmt5("{} = vl_obj_{}(L, {}, {}, {}, ", S(c), this.short(this.trait_of(t)), S(idx), move o, S(kp));
            a.get.append(fmt("{});", S(what)).as_str());
            return;
        },
        .CLOSURE(i) => {
            // a Lua function, which Volt calls during the call (vl_up_cbN)
            a.decl = fmt2("vl_lua {}_cb = {{L, {}, LUA_NOREF};", S(c), S(idx));
            a.get = fmt2("vl_callable(L, {}, {});", S(idx), S(what));
            a.pass = fmt2("vl_up_cb{}, &{}_cb", unum(@cast<u64>(i)), S(c));
            return;
        },
        .LIST(x) => {
            // a sequence: Volt copies its elements (and takes the handles)
            a.decl = fmt2("{} {};", this.c_prim(this.in_ty(t), false), S(c));
            a.get = this.lua_seq(this.list_elem(t), idx, c, what, kp, "2");
            return;
        },
        .SLICE(x) => {
            if (this.lua_keeps(t)) {
                // strings and handles, held for the call; Volt has handles' values for the call
                var how = S("1");
                match (this.shape_of(this.slice_elem(t)) ?? shape::VOID) {
                    .HANDLE(s) => { how = S("3"); },
                    default => {},
                }
                a.decl = fmt2("{} {};", this.c_prim(t, false), S(c));
                a.get = this.lua_seq(this.slice_elem(t), idx, c, what, kp, how.as_str());
                return;
            }
            if (this.node_simple(x)) {
                // what Volt wrote into the elements comes back
                a.after = fmt3("for (size_t i = 0; i < {}.len; i++) {{ {} lua_seti(L, {}, (lua_Integer)i + 1); }", S(c), this.lua_push(x, fmt("{}.ptr[i]", S(c)).as_str()), S(idx));
            }
        },
        .PTR(x) => {
            if (x != VOID && this.node_simple(x)) {
                // a struct (or number) by reference: a copy goes in, and what Volt changed comes back
                // into the table (a number has nowhere to go back to)
                val v = fmt("{}_val", S(c));
                a.decl = fmt2("{} {};", this.c_prim(x, false), copy v);
                var back: std::string = {};
                match (this.shape_of(x) ?? shape::VOID) {
                    .STRUCT(s) => { back = fmt3("vl_set_{}(L, {}, &{});", this.node_sname(s), S(idx), copy v); },
                    default => {},
                }
                if (this.is_ref(t)) {
                    a.get = this.lua_get(x, idx, v.as_str(), what);
                    a.pass = fmt("&{}", copy v);
                    a.after = move back;
                } else {
                    a.decl.append(fmt(" bool {}_null;", S(c)).as_str());
                    a.get = fmt4("{}_null = lua_isnoneornil(L, {}); if (!{}_null) {{ {} }", S(c), S(idx), S(c), this.lua_get(x, idx, v.as_str(), what));
                    a.pass = fmt2("({}_null ? NULL : &{})", S(c), copy v);
                    if (back.len() > 0) {
                        a.after = fmt2("if (!{}_null) {{ {} }", S(c), move back);
                    }
                }
                return;
            }
        },
        default => {},
    }
    // anything else crosses as itself (text as a str, an optional text as a str?)
    val v = this.in_ty(t);
    a.decl = fmt2("{} {};", this.c_prim(v, false), S(c));
    a.get = this.lua_get(v, idx, c, what);
}

// statements pushing C value r of type t (an export fn's result, or an argument of a Lua function
// Volt calls): what Volt gives becomes Lua's (text a string, a handle, Volt's object or closure a
// userdata that frees it, a list a sequence, then freed); E!T pushes its value when there's no error
attach fn lua_out(this: bind&, t: u32, r: str) -> std::string {
    match (this.shape_of(t) ?? shape::VOID) {
        .VOID => { return {}; },
        .TEXT(x) => { return fmt("vl_push_text(L, {});", S(r)); },
        .HANDLE(s) => { return fmt2("vl_wrap(L, {}, false, {});", S(r), this.lua_mt(this.node_sname(s).as_str())); },
        .TRAIT(i) => { return fmt3("vl_box(L, &{}, sizeof {}, {});", S(r), S(r), this.lua_mt(this.short(this.trait_of(t)).as_str())); },
        .CLOSURE(i) => { return fmt3("vl_box(L, &{}, sizeof {}, {});", S(r), S(r), this.lua_mt(fmt("closure{}", unum(@cast<u64>(i))).as_str())); },
        .LIST(x) => {
            // text lent until the list is freed, each handle the caller's
            val e = this.list_elem(t);
            val at = fmt2("{}.ptr[i{}]", S(r), lua_depth(r));
            var el = this.lua_push(this.view_of(e), at.as_str());
            if (this.handle_of(e) != null) {
                el = this.lua_out(e, at.as_str());
            }
            var s = this.lua_seq_out(this.view_of(e), r, move el);
            s.append(fmt(" volt_list_free({});", S(r)).as_str());
            return s;
        },
        .OPT(x) => {
            if (this.handle_of(x) != null) {
                return fmt2("if ({}) {{ {} }} else {{ lua_pushnil(L); }}", S(r), this.lua_out(x, r));
            }
            return fmt2("if ({}.has) {{ {} }} else {{ lua_pushnil(L); }}", S(r), this.lua_out(x, fmt("{}.value", S(r)).as_str()));
        },
        .RESULT(e, x) => {
            val v = this.lua_out(x, fmt("{}.value", S(r)).as_str());
            if (v.len() == 0) {
                return {};
            }
            return fmt2("if ({}.error == 0) {{ {} }", S(r), move v);
        },
        default => { return this.lua_push(t, r); },
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

// can Volt call into Lua (a callback, a Lua object)? Then each call into Volt raises what Lua raised
attach fn lua_upcalls(this: bind&) -> bool {
    return this.closures.len > 0 || this.traits.len > 0;
}

// vl_NAME, the C function behind a Lua function (lname in messages): its Lua arguments from first on
// (1 is the userdata a closure or Volt's object is called on, which pre checks) converted to ps's C
// forms, the call (callee with them, after self when there's one), the result pushed, then what a
// Lua function raised during the call, then Volt's error
attach fn lua_wrapper(this: bind&, name: str, lname: str, ps: std::vec<u32>&, names: std::vec<std::string>&, first: usize, pre: str, callee: str, self: str, ret: u32, out: std::string&) -> void {
    var keeps = false;
    for (p&) in ps.items() {
        if (this.lua_keeps(*p)) {
            keeps = true;
        }
    }
    var kp = S("0");
    out.append(fmt("\nstatic int vl_{}(lua_State *L) {{\n", S(name)).as_str());
    out.append(pre);
    // the arguments in their places (none missing: what conversions push goes after them)
    val top = unum(@cast<u64>(first - 1 + ps.len));
    out.append(fmt("    lua_settop(L, {});\n", copy top).as_str());
    if (keeps) {
        // the call's table, after the arguments
        kp = S("keep");
        out.append(fmt("    lua_newtable(L);\n    const int keep = {} + 1;\n", copy top).as_str());
    }
    var gets: std::string = {};
    var passes = S(self);
    var afters: std::string = {};
    for (k) in 0..ps.len {
        var a: lua_arg = {};
        val idx = unum(@cast<u64>(k + first));
        val what = fmt2("\"argument #{} to '{}'\"", copy idx, S(lname));
        this.lua_in(*ps.at(k), idx.as_str(), names.at(k).as_str(), what.as_str(), kp.as_str(), &a);
        out.append(fmt("    {}\n", copy a.decl).as_str());
        gets.append(fmt("    {}\n", copy a.get).as_str());
        if (passes.len() > 0) {
            passes.append(", ");
        }
        passes.append(a.pass.as_str());
        if (a.after.len() > 0) {
            afters.append(fmt("    {}\n", copy a.after).as_str());
        }
    }
    out.append(gets.as_str());
    if (keeps) {
        out.append("    vl_give_all(L, keep);\n");
    }
    val call = fmt2("{}({})", S(callee), move passes);
    if (ret == VOID) {
        out.append(fmt("    {};\n", move call).as_str());
    } else {
        out.append(fmt2("    {}r = {};\n", spaced(this.c_out(ret, false)), move call).as_str());
    }
    val res = this.lua_out(ret, "r");
    if (res.len() > 0) {
        out.append(fmt("    {}\n", copy res).as_str());
    }
    if (this.lua_upcalls()) {
        out.append("    vl_reraise(L);\n");
    }
    match (this.shape_of(ret) ?? shape::VOID) {
        .RESULT(e, x) => { out.append("    if (r.error != 0) {\n        return vl_raise(L, r.error);\n    }\n"); },
        default => {},
    }
    out.append(afters.as_str());
    out.append(fmt("    return {};\n}\n", unum(@cast<u64>(this.lua_count(ret)))).as_str());
}

// what Volt gets for E!T when the Lua function giving it raised: E's first error
attach fn lua_first_code(this: bind&, e: u32) -> std::string {
    match (*this.c.t.get(e)) {
        .ENUM(id) => {
            if (this.c.ei(id).values.len > 0) {
                return fmt("{}u", num(*this.c.ei(id).values.at(0)));
            }
        },
        default => {},
    }
    val all = this.all_codes();
    if (all.len > 0) {
        return fmt("{}u", num(all.at(0).code));
    }
    return S("1u");
}

// statements converting what a Lua function gave back into C lvalue c of type r, as Volt takes it:
// text copied, a handle given up, and for E!T Lua's `value` or `nil, err` (err an error's name, or an
// error from Volt)
attach fn lua_up_get(this: bind&, r: u32, c: str, what: str) -> std::string {
    match (this.shape_of(r) ?? shape::VOID) {
        .TEXT(x) => { return fmt2("{} = vl_give_text(L, -1, {});", S(c), S(what)); },
        .HANDLE(s) => { return fmt3("{} = vl_take(vl_handle_in(L, -1, {}, 0, 2, {}));", S(c), this.lua_mt(this.node_sname(s).as_str()), S(what)); },
        .RESULT(e, x) => {
            var s = fmt3("if (!lua_isnil(L, -1)) {{ {}.error = {}(L, -1, {}); }} else {{ ", S(c), this.lua_code_fn(e), S(what));
            s.append(fmt2("{} {}.error = 0; }", this.lua_get(x, "-2", fmt("{}.value", S(c)).as_str(), what), S(c)).as_str());
            return s;
        },
        default => { return this.lua_get(r, "-1", c, what); },
    }
}

// vl_up_NAME, the C function Volt calls for a Lua function (method: the Lua object's method of that
// name), taking self (a vl_lua) then ps, giving r; and vl_run_NAME, which calls the Lua function and
// converts what it gives back, in a protected call. When it raises, Volt gets a stand-in (zeros,
// empty text, E!T's first error) and the error is kept for the call into Volt to raise; nothing
// stands in for a handle, so the program stops
attach fn lua_upcall(this: bind&, name: str, method: str, ps: std::vec<u32>&, r: u32) -> std::string {
    val rc = this.c_prim(r, false);
    val rs = this.shape_of(r) ?? shape::VOID;
    var gives_handle = false;
    var nres = S("1");
    match (rs) {
        .VOID => { nres = S("0"); },
        .RESULT(e, x) => { nres = S("2"); },
        .HANDLE(s) => { gives_handle = true; },
        default => {},
    }
    var what = S("\"the callback's result\"");
    if (method.len > 0) {
        what = fmt("\"the result of method {}\"", S(method));
    }
    var out = fmt("\n// 1: where the result goes, 2: the Lua function (or object), then its arguments\nstatic inline int vl_run_{}(lua_State *L) {{\n", S(name));
    if (r != VOID) {
        out.append(fmt("    {}*out = lua_touserdata(L, 1);\n", spaced(copy rc)).as_str());
    }
    out.append("    lua_remove(L, 1);\n");
    if (method.len > 0) {
        out.append(fmt("    lua_getfield(L, 1, \"{}\");\n    lua_insert(L, 1);\n", S(method)).as_str());
    }
    out.append(fmt("    lua_call(L, lua_gettop(L) - 1, {});\n", move nres).as_str());
    if (r != VOID) {
        out.append(fmt("    {}\n", this.lua_up_get(r, "(*out)", what.as_str())).as_str());
        // what the result points into (a string, a slice's memory) is held until the next one
        var held = r;
        match (rs) {
            .RESULT(e, x) => { held = x; },
            default => {},
        }
        if (held != VOID && !this.node_simple(held) && !this.owned_result(this.shape_of(held) ?? shape::VOID)) {
            out.append("    vl_keep_results(L);\n");
        }
    }
    out.append("    return 0;\n}\n");
    var params = S("void *self");
    for (k) in 0..ps.len {
        params.append(fmt2(", {}a{}", spaced(this.c_in(*ps.at(k), false)), unum(@cast<u64>(k))).as_str());
    }
    out.append(fmt3("\nstatic inline {}vl_up_{}({}) {{\n    vl_lua *c = self;\n    lua_State *L = c->L;\n", spaced(copy rc), S(name), move params).as_str());
    out.append(fmt("    vl_room(L, {});\n", unum(@cast<u64>(ps.len * 2 + 4))).as_str());
    var ret = S("return;");
    var place = S("NULL");
    if (r != VOID) {
        out.append(fmt("    {}out;\n    memset(&out, 0, sizeof out);\n", spaced(copy rc)).as_str());
        match (rs) {
            .TEXT(x) => { out.append("    out = vl_no_text();\n"); },
            .RESULT(e, x) => { out.append(fmt("    out.error = {};\n", this.lua_first_code(e)).as_str()); },
            default => {},
        }
        ret = S("return out;");
        place = S("&out");
    }
    if (!gives_handle) {
        // skipped: the handles Volt gives it are freed
        var frees: std::string = {};
        for (k) in 0..ps.len {
            match (this.shape_of(*ps.at(k)) ?? shape::VOID) {
                .HANDLE(s) => { frees.append(fmt2("        {}(a{});\n", this.free_name(s), unum(@cast<u64>(k))).as_str()); },
                default => {},
            }
        }
        out.append(fmt2("    if (vl_failed(L)) {{\n{}        {}\n    }}\n", move frees, copy ret).as_str());
    }
    // a handle Volt lends: a userdata closed when the Lua function returns
    var lent = false;
    var closes: std::string = {};
    for (k) in 0..ps.len {
        val h = this.lent_handle(*ps.at(k));
        if (h) {
            if (!lent) {
                out.append("    int base = lua_gettop(L);\n");
                lent = true;
            }
            val kk = unum(@cast<u64>(k));
            out.append(fmt4("    vl_handle *u{} = vl_wrap(L, a{}, true, {});\n    int k{} = lua_gettop(L);\n", copy kk, copy kk, this.lua_mt(this.node_sname(h).as_str()), copy kk).as_str());
            closes.append(fmt("    u{}->h = NULL;\n", copy kk).as_str());
        }
    }
    out.append(fmt2("    lua_pushcfunction(L, vl_run_{});\n    lua_pushlightuserdata(L, {});\n    vl_push_lua(c);\n", S(name), move place).as_str());
    for (k) in 0..ps.len {
        val kk = unum(@cast<u64>(k));
        if (this.lent_handle(*ps.at(k)) != null) {
            out.append(fmt("    lua_pushvalue(L, k{});\n", copy kk).as_str());
        } else {
            out.append(fmt("    {}\n", this.lua_out(this.in_ty(*ps.at(k)), fmt("a{}", copy kk).as_str())).as_str());
        }
    }
    out.append(fmt("    if (lua_pcall(L, {}, 0, 0) != LUA_OK) {{\n", unum(@cast<u64>(ps.len + 2))).as_str());
    if (gives_handle) {
        out.append("        vl_die(L);\n    }\n");
    } else {
        out.append("        vl_keep_error(L);\n    }\n");
    }
    if (lent) {
        out.append(closes.as_str());
        out.append("    lua_settop(L, base);\n");
    }
    out.append(fmt("    {}\n}\n", move ret).as_str());
    return out;
}

// vl_close_NAME, close, __close and __gc (with a true upvalue) of a userdata of Volt's: free is the
// statements freeing what it holds, once; what a Lua function raised meanwhile comes out of close and
// __close (see vl_drop_begin)
attach fn lua_close_fn(this: bind&, name: str, cn: str, free: str) -> std::string {
    var out = fmt3("\n// close, __close and __gc: frees it (once)\nstatic int vl_close_{}(lua_State *L) {{\n    {}*o = luaL_checkudata(L, 1, {});\n", S(name), spaced(S(cn)), this.lua_mt(name));
    if (!this.lua_upcalls()) {
        out.append(fmt("{}    return 0;\n}\n", S(free)).as_str());
        return out;
    }
    out.append(fmt("    int gc = lua_toboolean(L, lua_upvalueindex(1));\n    vl_drop_begin(L, gc);\n{}    vl_drop_end(L, gc);\n    return 0;\n}\n", S(free)).as_str());
    return out;
}

// statements freeing Volt's object or closure o (first, its first field, is NULL once it's closed)
fn lua_drop(first: str) -> std::string {
    return fmt2("    if (o->{}) {{\n        o->{} = NULL;\n        if (o->drop) {{\n            o->drop(o->self);\n        }}\n    }}\n", S(first), S(first));
}

// a metatable in luaopen, left on the stack: __index (close, then the methods), __gc and __close
attach fn lua_meta(this: bind&, name: str, methods: str) -> std::string {
    var out = fmt2("    luaL_newmetatable(L, {});\n    lua_newtable(L);\n    lua_pushcfunction(L, vl_close_{});\n    lua_setfield(L, -2, \"close\");\n", this.lua_mt(name), S(name));
    out.append(methods);
    out.append(fmt2("    lua_setfield(L, -2, \"__index\");\n    lua_pushboolean(L, 1);\n    lua_pushcclosure(L, vl_close_{}, 1);\n    lua_setfield(L, -2, \"__gc\");\n    lua_pushcfunction(L, vl_close_{});\n    lua_setfield(L, -2, \"__close\");\n", S(name), S(name)).as_str());
    return out;
}

// trait k: a Lua object with its methods, lent or given to Volt (vl_obj_T makes Volt's object of it,
// whose table, vl_up_T_fn, calls the methods), and Volt's own object, a userdata whose methods call
// its table
attach fn lua_trait(this: bind&, k: u32, out: std::string&) -> void {
    val t = *this.traits.at(k);
    val tr = this.short(t);
    val on = this.c_named(tr.as_str(), false);
    var vt = copy tr;
    vt.append("_vt");
    val fns = this.fns_of(t);
    var table: std::string = {};
    var names: std::string = {};
    for (f&) in fns.items() {
        val n = fmt2("{}_{}", copy tr, S(f.name));
        out.append(this.lua_upcall(n.as_str(), f.name, &f.params, f.ret).as_str());
        if (table.len() > 0) {
            table.append(", ");
        }
        table.append(fmt("vl_up_{}", copy n).as_str());
        names.append(fmt("\"{}\", ", S(f.name)).as_str());
    }
    val mt = this.lua_mt(tr.as_str());
    out.append(fmt3("\n// a {} for Volt from the value at idx: Volt's own (lent, or given: closed once the call takes it), or a\n// Lua object with its methods, lent (o: on the stack for the call) or given (held until Volt drops it)\nstatic inline {} vl_obj_{}(", copy tr, copy on, copy tr).as_str());
    out.append(fmt3("lua_State *L, int idx, vl_lua *o, int keep, const char *what) {{\n    static const char *const fns[] = {{{}NULL}};\n    static const {} vt = {{{}}};\n", move names, this.c_named(vt.as_str(), false), move table).as_str());
    out.append(fmt4("    {}*v = luaL_testudata(L, idx, {});\n    if (v) {{\n        vl_open(L, idx, {}, what);\n        vl_mark(L, keep, idx, o ? 1 : 2, what);\n        return *v;\n    }}\n    vl_check_obj(L, idx, \"{}\", fns, what);\n", spaced(copy on), copy mt, copy mt, copy tr).as_str());
    out.append(fmt("    {} r = {{&vt, o, NULL};\n    if (!o) {{\n        r.self = vl_holder(L, idx, keep, what);\n        r.drop = vl_drop_lua;\n    }}\n    return r;\n}\n", copy on).as_str());
    // Volt's own: each method calls its table
    for (f&) in fns.items() {
        val ln = fmt2("{}:{}", copy tr, S(f.name));
        var pnames: std::vec<std::string> = {};
        for (q) in 0..f.params.len {
            put(&pnames, fmt("p_{}", unum(@cast<u64>(q))));
        }
        val pre = fmt3("    {}*self = vl_open(L, 1, {}, \"argument #1 to '{}'\");\n", spaced(copy on), copy mt, copy ln);
        this.lua_wrapper(fmt2("m_{}_{}", copy tr, S(f.name)).as_str(), ln.as_str(), &f.params, &pnames, 2, pre.as_str(), fmt("self->vt->{}", S(f.name)).as_str(), "self->self", f.ret, out);
    }
    out.append(this.lua_close_fn(tr.as_str(), on.as_str(), lua_drop("vt").as_str()).as_str());
}

attach fn lua_text(this: bind&) -> compile_error!std::string {
    val ents = this.entries();
    val p = this.pkg;
    var out = fmt("// {}: generated by voltc bindings; a Lua (5.4 or later) C module for the Volt package.\n", S(p));
    out.append(fmt3("// Build it against the library and Lua's headers:\n//   cc -shared -fPIC {}_lua.c -L. -l{} -o {}.so\n", S(p), S(p), S(p)).as_str());
    out.append(fmt("// then require \"{}\". An error is raised as a table with its name and code.\n#include <lua.h>\n#include <lauxlib.h>\n#include <limits.h>\n#include <stdio.h>\n#include <stdlib.h>\n#include <string.h>\n\n", S(p)).as_str());
    out.append(this.c_text().as_str());
    out.append(fmt3("\n// the error metatable; where the registry keeps the error a Lua function raised while Volt called\n// it, and what the last one gave Volt\n#define VL_ERROR \"{}.error\"\n#define VL_RAISED \"{}.raised\"\n#define VL_KEPT \"{}.kept\"\n", S(p), S(p), S(p)).as_str());
    out.append(r"""

        // ---------- conversions: each raises an error naming what didn't fit ----------

        static inline lua_Integer vl_int(lua_State *L, int idx, lua_Integer lo, lua_Integer hi, const char *what) {
            int ok = 0;
            lua_Integer v = lua_tointegerx(L, idx, &ok);
            if (!ok) {
                luaL_error(L, "%s: expected an integer, got %s", what, luaL_typename(L, idx));
            }
            if (v < lo || v > hi) {
                luaL_error(L, "%s: %I doesn't fit", what, v);
            }
            return v;
        }

        static inline lua_Number vl_num(lua_State *L, int idx, const char *what) {
            int ok = 0;
            lua_Number v = lua_tonumberx(L, idx, &ok);
            if (!ok) {
                luaL_error(L, "%s: expected a number, got %s", what, luaL_typename(L, idx));
            }
            return v;
        }

        static inline bool vl_bool(lua_State *L, int idx, const char *what) {
            if (!lua_isboolean(L, idx)) {
                luaL_error(L, "%s: expected a boolean, got %s", what, luaL_typename(L, idx));
            }
            return lua_toboolean(L, idx);
        }

        // a string's bytes (Lua keeps them while the string is on the stack, or in a table there)
        static inline const char *vl_str(lua_State *L, int idx, size_t *len, const char *what) {
            if (lua_type(L, idx) != LUA_TSTRING) {
                luaL_error(L, "%s: expected a string, got %s", what, luaL_typename(L, idx));
            }
            return lua_tolstring(L, idx, len);
        }

        // a sequence's length: its n field when it has one (as table.pack gives, for nil elements), else #
        static inline size_t vl_seq(lua_State *L, int idx, const char *what) {
            if (!lua_istable(L, idx)) {
                luaL_error(L, "%s: expected a table, got %s", what, luaL_typename(L, idx));
            }
            lua_Integer n = lua_getfield(L, idx, "n") == LUA_TNUMBER && lua_isinteger(L, -1) ? lua_tointeger(L, -1) : -1;
            lua_pop(L, 1);
            if (n < 0) {
                n = luaL_len(L, idx);
            }
            if (n < 0) {
                luaL_error(L, "%s: a negative length", what);
            }
            return (size_t)n;
        }

        // memory for n elements of size bytes: a userdata left on the stack (collected after the call)
        static inline void *vl_buffer(lua_State *L, size_t size, size_t n) {
            if (n > SIZE_MAX / size) {
                luaL_error(L, "a sequence of %I elements is too long", (lua_Integer)n);
            }
            luaL_checkstack(L, 1, "too many slices in one call");
            return lua_newuserdatauv(L, n ? size * n : 1, 0);
        }

        static inline void *vl_pointer(lua_State *L, int idx, const char *what) {
            if (!lua_islightuserdata(L, idx)) {
                luaL_error(L, "%s: expected a pointer from this library, got %s", what, luaL_typename(L, idx));
            }
            return lua_touserdata(L, idx);
        }

        // ---------- userdata, and what a call into Volt takes ----------
        // Every userdata here starts with what it holds (a handle, Volt's object's table, a closure's
        // function), NULL once it's closed or given to Volt

        // an export struct's userdata: its handle, and whether Volt only lends it to Lua (then Lua never
        // frees it, and it's closed when the Lua function it was lent to returns)
        typedef struct {
            void *h;
            bool lent;
        } vl_handle;

        static inline vl_handle *vl_wrap(lua_State *L, void *h, bool lent, const char *mt) {
            vl_handle *u = lua_newuserdatauv(L, sizeof *u, 0);
            u->h = h;
            u->lent = lent;
            luaL_setmetatable(L, mt);
            return u;
        }

        // pushes a userdata holding a copy of Volt's object or closure v (n bytes)
        static inline void vl_box(lua_State *L, const void *v, size_t n, const char *mt) {
            memcpy(lua_newuserdatauv(L, n, 0), v, n);
            luaL_setmetatable(L, mt);
        }

        // the open userdata at idx with metatable mt ("pkg.name"): an error when it's something else, or
        // closed
        static inline void *vl_open(lua_State *L, int idx, const char *mt, const char *what) {
            void **u = luaL_testudata(L, idx, mt);
            if (!u) {
                luaL_error(L, "%s: expected a %s, got %s", what, strchr(mt, '.') + 1, luaL_typename(L, idx));
            }
            if (!*u) {
                luaL_error(L, "%s: this %s is closed", what, strchr(mt, '.') + 1);
            }
            return u;
        }

        // the table at keep (0: none) of what a call passes Volt, which holds it for the call: a value
        // Volt takes (how 2: given, 3: copied in for the call) goes once, one it lends (1) any number of
        // times; 4 marks the holder of a Lua object given to Volt
        static inline void vl_mark(lua_State *L, int keep, int idx, int how, const char *what) {
            if (!keep) {
                return;
            }
            idx = lua_absindex(L, idx);
            lua_pushvalue(L, idx);
            int had = lua_rawget(L, keep) == LUA_TNIL ? 0 : (int)lua_tointeger(L, -1);
            lua_pop(L, 1);
            if (had && (had != 1 || how != 1)) {
                luaL_error(L, "%s: Volt takes this %s, so it can't be passed twice in one call", what, luaL_typename(L, idx));
            }
            lua_pushvalue(L, idx);
            lua_pushinteger(L, how);
            lua_rawset(L, keep);
        }

        // the export struct's userdata at idx (metatable mt), its handle lent to Volt (how 1), given (2,
        // which only an owner can) or copied in for the call (3)
        static inline vl_handle *vl_handle_in(lua_State *L, int idx, const char *mt, int keep, int how, const char *what) {
            vl_handle *u = vl_open(L, idx, mt, what);
            if (how == 2 && u->lent) {
                luaL_error(L, "%s: this %s is only lent to Lua", what, strchr(mt, '.') + 1);
            }
            vl_mark(L, keep, idx, how, what);
            return u;
        }

        // a handle a Lua function gives Volt: its userdata is closed
        static inline void *vl_take(vl_handle *u) {
            void *h = u->h;
            u->h = NULL;
            return h;
        }

        // a Lua value Volt calls: at idx on L's stack while a call lends it, or (given) in the registry
        // (ref) as the user value of this holder
        typedef struct {
            lua_State *L;
            int idx;
            int ref;
        } vl_lua;

        static inline void vl_push_lua(vl_lua *o) {
            if (o->ref == LUA_NOREF) {
                lua_pushvalue(o->L, o->idx);
                return;
            }
            lua_rawgeti(o->L, LUA_REGISTRYINDEX, o->ref);
            lua_getiuservalue(o->L, -1, 1);
            lua_remove(o->L, -2);
        }

        // a holder of the Lua value at idx, given to Volt: Volt calls it on the main thread, and it's
        // anchored in the registry once the call takes it (vl_give_all) until Volt drops it
        static inline vl_lua *vl_holder(lua_State *L, int idx, int keep, const char *what) {
            idx = lua_absindex(L, idx);
            vl_lua *o = lua_newuserdatauv(L, sizeof *o, 1);
            lua_rawgeti(L, LUA_REGISTRYINDEX, LUA_RIDX_MAINTHREAD);
            o->L = lua_tothread(L, -1);
            lua_pop(L, 1);
            o->idx = 0;
            o->ref = LUA_NOREF;
            lua_pushvalue(L, idx);
            lua_setiuservalue(L, -2, 1);
            vl_mark(L, keep, -1, 4, what);
            return o;
        }

        // gives Volt what the call takes, once every argument has converted: each userdata given (2) is
        // closed, each holder (4) anchored
        static inline void vl_give_all(lua_State *L, int keep) {
            lua_pushnil(L);
            while (lua_next(L, keep)) {
                lua_Integer how = lua_tointeger(L, -1);
                lua_pop(L, 1);
                if (how == 2) {
                    *(void **)lua_touserdata(L, -1) = NULL;
                } else if (how == 4) {
                    vl_lua *o = lua_touserdata(L, -1);
                    lua_pushvalue(L, -1);
                    o->ref = luaL_ref(L, LUA_REGISTRYINDEX);
                }
            }
        }

        // ---------- Lua functions Volt calls ----------

        // the first error a Lua function raised while Volt called it: kept in the registry (Volt gets a
        // stand-in, and the later calls into Lua are skipped) until the call into Volt is back and
        // raises it
        static inline void vl_keep_error(lua_State *L) {
            if (lua_isnil(L, -1)) {
                lua_pop(L, 1);
                lua_pushliteral(L, "a Lua function Volt called raised nil");
            }
            if (lua_getfield(L, LUA_REGISTRYINDEX, VL_RAISED) == LUA_TNIL) {
                lua_pop(L, 1);
                lua_setfield(L, LUA_REGISTRYINDEX, VL_RAISED);
            } else {
                lua_pop(L, 2);
            }
        }

        static inline bool vl_failed(lua_State *L) {
            bool failed = lua_getfield(L, LUA_REGISTRYINDEX, VL_RAISED) != LUA_TNIL;
            lua_pop(L, 1);
            return failed;
        }

        // after a call into Volt: raises what a Lua function raised during it
        static inline void vl_reraise(lua_State *L) {
            if (lua_getfield(L, LUA_REGISTRYINDEX, VL_RAISED) != LUA_TNIL) {
                lua_pushnil(L);
                lua_setfield(L, LUA_REGISTRYINDEX, VL_RAISED);
                lua_error(L);
            }
            lua_pop(L, 1);
        }

        // around a drop: in __gc (gc), a call into Volt's pending error stays pending and what the drop
        // raised is dropped (the collector runs whenever Lua allocates); in close and __close, what it
        // raised is raised
        static inline void vl_drop_begin(lua_State *L, int gc) {
            if (gc) {
                lua_getfield(L, LUA_REGISTRYINDEX, VL_RAISED);
                lua_pushnil(L);
                lua_setfield(L, LUA_REGISTRYINDEX, VL_RAISED);
            }
        }

        static inline void vl_drop_end(lua_State *L, int gc) {
            if (gc) {
                lua_setfield(L, LUA_REGISTRYINDEX, VL_RAISED);
            } else {
                vl_reraise(L);
            }
        }

        // a callback: a function, or anything with __call (a closure Volt gave back)
        static inline void vl_callable(lua_State *L, int idx, const char *what) {
            if (lua_isfunction(L, idx)) {
                return;
            }
            if (luaL_getmetafield(L, idx, "__call") != LUA_TNIL) {
                lua_pop(L, 1);
                return;
            }
            luaL_error(L, "%s: expected a function, got %s", what, luaL_typename(L, idx));
        }

        // holds what a Lua function gave Volt (strings, slices' memory: the stack) until the next one
        // gives its own
        // ponytail: Volt reads a result before it calls Lua again; hold more if a fn keeps two
        static inline void vl_keep_results(lua_State *L) {
            int n = lua_gettop(L);
            lua_createtable(L, n, 0);
            for (int i = 1; i <= n; i++) {
                lua_pushvalue(L, i);
                lua_rawseti(L, -2, i);
            }
            lua_setfield(L, LUA_REGISTRYINDEX, VL_KEPT);
        }

        // room for n values on the stack, to call a Lua function: without it nothing runs, so the program
        // stops, as a Volt panic does (Lua's stack holds a million)
        static inline void vl_room(lua_State *L, int n) {
            if (!lua_checkstack(L, n)) {
                fprintf(stderr, "panic: Lua's stack is full\n");
                exit(101);
            }
        }

        // a Lua function that had to give Volt a handle raised: nothing can stand in, so the program
        // stops, as a Volt panic does
        static inline void vl_die(lua_State *L) {
            const char *m = lua_tostring(L, -1);
            fprintf(stderr, "panic: a Lua function giving Volt a handle raised: %s\n", m ? m : luaL_typename(L, -1));
            exit(101);
        }

        // checks the value at idx is a Lua object with each method in fns (a table or a userdata)
        static inline void vl_check_obj(lua_State *L, int idx, const char *trait, const char *const *fns, const char *what) {
            if (!lua_istable(L, idx) && lua_type(L, idx) != LUA_TUSERDATA) {
                luaL_error(L, "%s: expected a %s, got %s", what, trait, luaL_typename(L, idx));
            }
            for (; *fns; fns++) {
                if (lua_getfield(L, idx, *fns) == LUA_TNIL) {
                    luaL_error(L, "%s: expected a %s, got a %s without %s", what, trait, luaL_typename(L, idx), *fns);
                }
                lua_pop(L, 1);
            }
        }

        // Volt is done with a Lua object it was given: its close method runs (when it has one), and it's
        // let go
        static inline int vl_run_close(lua_State *L) {
            if (lua_getfield(L, 1, "close") != LUA_TNIL) {
                lua_insert(L, 1);
                lua_call(L, 1, 0);
            }
            return 0;
        }

        static inline void vl_drop_lua(void *self) {
            vl_lua *o = self;
            lua_State *L = o->L;
            vl_room(L, 3);
            lua_pushcfunction(L, vl_run_close);
            vl_push_lua(o);
            if (lua_pcall(L, 1, 0, 0) != LUA_OK) {
                vl_keep_error(L);
            }
            luaL_unref(L, LUA_REGISTRYINDEX, o->ref);
        }

        """);
    if (this.texts.len > 0) {
        out.append(r"""
            // owned text: a Lua string, and the text freed
            static inline void vl_push_text(lua_State *L, volt_text t) {
                lua_pushlstring(L, (const char *)t.ptr, t.len);
                volt_text_free(t);
            }

            // text for Volt, copied from the string at idx (Volt frees it)
            static inline volt_text vl_give_text(lua_State *L, int idx, const char *what) {
                size_t n;
                const char *s = vl_str(L, idx, &n, what);
                char *b = malloc(n ? n : 1);
                if (!b) {
                    luaL_error(L, "out of memory");
                }
                memcpy(b, s, n);
                volt_text t = {(const uint8_t *)b, n, b, free};
                return t;
            }

            static inline void vl_no_drop(void *owner) {
                (void)owner;
            }

            // what Volt gets for text when the Lua function giving it raised
            static inline volt_text vl_no_text(void) {
                volt_text t = {(const uint8_t *)"", 0, NULL, vl_no_drop};
                return t;
            }

            """);
    }
    // errors: a table {name = NAME, code = N} whose tostring is its name
    out.append("// ---------- errors: a table {name = NAME, code = N}, whose tostring is its name ----------\n\nstatic inline const char *vl_error_name(uint32_t code) {\n    switch (code) {\n");
    for (c&) in this.all_codes().items() {
        out.append(fmt2("    case {}u: return \"{}\";\n", num(c.code), S(c.name)).as_str());
    }
    out.append(r"""
            }
            return "ERROR";
        }

        static inline void vl_push_error(lua_State *L, uint32_t code) {
            lua_createtable(L, 0, 2);
            lua_pushstring(L, vl_error_name(code));
            lua_setfield(L, -2, "name");
            lua_pushinteger(L, (lua_Integer)code);
            lua_setfield(L, -2, "code");
            luaL_setmetatable(L, VL_ERROR);
        }

        static inline int vl_raise(lua_State *L, uint32_t code) {
            vl_push_error(L, code);
            return lua_error(L);
        }

        static int vl_error_tostring(lua_State *L) {
            lua_getfield(L, 1, "name");
            return 1;
        }

        // is the value at idx an error from Volt?
        static inline bool vl_is_error(lua_State *L, int idx) {
            bool is = false;
            if (lua_getmetatable(L, idx)) {
                luaL_getmetatable(L, VL_ERROR);
                is = lua_rawequal(L, -1, -2);
                lua_pop(L, 2);
            }
            return is;
        }

        // the name of the error a Lua function gives Volt: a string (one of the module's error sets'
        // names), or an error from Volt
        static inline const char *vl_error_of(lua_State *L, int idx, const char *what) {
            idx = lua_absindex(L, idx);
            if (lua_istable(L, idx)) {
                lua_getfield(L, idx, "name");
                lua_replace(L, idx);
            }
            return vl_str(L, idx, NULL, what);
        }

        """);
    // each error set's codes by name (vl_code_any: any error's)
    var sets: std::vec<std::string> = {};
    var codes: std::vec<std::vec<code_name>> = {};
    for (et&) in this.codes.items() {
        match (*this.c.t.get(*et)) {
            .ENUM(e) => {
                val info = this.c.ei(e);
                var cs: std::vec<code_name> = {};
                for (i) in 0..info.names.len {
                    put(&cs, { code: *info.values.at(i), name: *info.names.at(i), set: this.local(info.name) });
                }
                put(&sets, this.short(*et));
                put(&codes, move cs);
            },
            default => {},
        }
    }
    put(&sets, S("any"));
    put(&codes, this.all_codes());
    for (i) in 0..sets.len {
        out.append(fmt("\nstatic inline uint32_t vl_code_{}(lua_State *L, int idx, const char *what) {{\n    const char *n = vl_error_of(L, idx, what);\n", copy *sets.at(i)).as_str());
        for (c&) in codes.at(i).items() {
            out.append(fmt2("    if (strcmp(n, \"{}\") == 0) {{\n        return {}u;\n    }}\n", S(c.name), num(c.code)).as_str());
        }
        out.append(fmt("    luaL_error(L, \"%s: %s isn't an error of {}\", what, n);\n    return 0;\n}\n", copy *sets.at(i)).as_str());
    }
    // structs: to and from tables
    for (s&) in this.structs.items() {
        val sn = this.node_sname(*s);
        val cn = this.c_named(this.c.si(*s).name, false);
        out.append(fmt2("\nstatic inline void vl_get_{}(lua_State *L, int idx, {} *out, const char *what) {{\n    idx = lua_absindex(L, idx);\n    if (!lua_istable(L, idx)) {{\n", copy sn, copy cn).as_str());
        out.append("        luaL_error(L, \"%s: expected a table, got %s\", what, luaL_typename(L, idx));\n    }\n");
        for (f&) in this.c.si(*s).fields.items() {
            val fw = fmt2("\"field {} of {}\"", S(f.name), copy sn);
            out.append(fmt2("    {{\n        lua_getfield(L, idx, \"{}\");\n        int at = lua_gettop(L);\n        {}\n        lua_remove(L, at);\n    }}\n", S(f.name), this.lua_get(f.ty, "at", fmt("out->{}", S(f.name)).as_str(), fw.as_str())).as_str());
        }
        out.append("}\n");
        out.append(fmt2("\nstatic inline void vl_set_{}(lua_State *L, int idx, const {} *in) {{\n    idx = lua_absindex(L, idx);\n", copy sn, copy cn).as_str());
        for (f&) in this.c.si(*s).fields.items() {
            out.append(fmt2("    {}\n    lua_setfield(L, idx, \"{}\");\n", this.lua_push(f.ty, fmt("in->{}", S(f.name)).as_str()), S(f.name)).as_str());
        }
        out.append("}\n");
        out.append(fmt3("\nstatic inline void vl_new_{}(lua_State *L, const {} *in) {{\n    lua_newtable(L);\n    vl_set_{}(L, -1, in);\n}}\n", copy sn, copy cn, copy sn).as_str());
    }
    // callbacks: the C function each closure parameter's Lua function is called through
    var cbs: std::vec<u32> = {};
    for (f&) in this.exports().items() {
        for (q&) in this.c.fi(*f).params.items() {
            match (this.shape_of(q.ty) ?? shape::VOID) {
                .CLOSURE(i) => { add_u32(&cbs, i); },
                default => {},
            }
        }
    }
    for (i&) in cbs.items() {
        var ps: std::vec<u32> = {};
        val r = this.fn_parts(*this.closures.at(*i), &ps);
        out.append(this.lua_upcall(fmt("cb{}", unum(@cast<u64>(*i))).as_str(), "", &ps, r).as_str());
    }
    // classes: a userdata holding the handle
    for (s&) in this.handles.items() {
        val sn = this.node_sname(*s);
        // the handle is freed once, and never a lent one
        val free = fmt("    if (o->h) {{\n        if (!o->lent) {{\n            {}(o->h);\n        }}\n        o->h = NULL;\n    }}\n", this.free_name(*s));
        out.append(this.lua_close_fn(sn.as_str(), "vl_handle", free.as_str()).as_str());
    }
    // traits
    for (k) in 0..this.traits.len {
        this.lua_trait(@cast<u32>(k), &out);
    }
    // closures given back: a userdata called like a function
    for (i) in 0..this.closures.len {
        if (!has_u32(&this.closures_out, @cast<u32>(i))) {
            continue;
        }
        var ps: std::vec<u32> = {};
        val r = this.fn_parts(*this.closures.at(i), &ps);
        val n = fmt("closure{}", unum(@cast<u64>(i)));
        val cn = this.c_named(n.as_str(), false);
        var pnames: std::vec<std::string> = {};
        for (q) in 0..ps.len {
            put(&pnames, fmt("p_{}", unum(@cast<u64>(q))));
        }
        val pre = fmt3("    {}*self = vl_open(L, 1, {}, \"argument #1 to '{}'\");\n", spaced(copy cn), this.lua_mt(n.as_str()), copy n);
        this.lua_wrapper(n.as_str(), n.as_str(), &ps, &pnames, 2, pre.as_str(), "self->call", "self->self", r, &out);
        out.append(this.lua_close_fn(n.as_str(), cn.as_str(), lua_drop("call").as_str()).as_str());
    }
    // the functions
    for (e&) in ents.items() {
        if (e.free_of == null) {
            val info = this.c.fi(e.f);
            var ps: std::vec<u32> = {};
            var pnames: std::vec<std::string> = {};
            for (q&) in info.params.items() {
                put(&ps, q.ty);
                put(&pnames, fmt("p_{}", S(q.name)));
            }
            this.lua_wrapper(fmt("f_{}", S(info.c_name)).as_str(), info.c_name, &ps, &pnames, 1, "", info.c_name, "", info.ret, &out);
        }
    }
    // the module: its functions, enums (tables of numbers), error sets (tables of names) and classes
    out.append(fmt("\nLUAMOD_API int luaopen_{}(lua_State *L) {{\n", S(p)).as_str());
    out.append("    luaL_newmetatable(L, VL_ERROR);\n    lua_pushcfunction(L, vl_error_tostring);\n    lua_setfield(L, -2, \"__tostring\");\n    lua_pop(L, 1);\n");
    for (k) in 0..this.traits.len {
        val tr = this.short(*this.traits.at(k));
        var methods: std::string = {};
        for (f&) in this.fns_of(*this.traits.at(k)).items() {
            methods.append(fmt3("    lua_pushcfunction(L, vl_m_{}_{});\n    lua_setfield(L, -2, \"{}\");\n", copy tr, S(f.name), S(f.name)).as_str());
        }
        out.append(this.lua_meta(tr.as_str(), methods.as_str()).as_str());
        out.append("    lua_pop(L, 1);\n");
    }
    for (i) in 0..this.closures.len {
        if (has_u32(&this.closures_out, @cast<u32>(i))) {
            val n = fmt("closure{}", unum(@cast<u64>(i)));
            out.append(this.lua_meta(n.as_str(), "").as_str());
            out.append(fmt("    lua_pushcfunction(L, vl_{});\n    lua_setfield(L, -2, \"__call\");\n    lua_pop(L, 1);\n", copy n).as_str());
        }
    }
    out.append("    lua_newtable(L);\n");
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
        var methods: std::string = {};
        var statics: std::string = {};
        for (e&) in ents.items() {
            if (e.free_of != null) {
                continue;
            }
            val m = this.member_of(e.f, *s) ?? continue;
            val line = fmt2("    lua_pushcfunction(L, vl_f_{});\n    lua_setfield(L, -2, \"{}\");\n", S(this.c.fi(e.f).c_name), S(m));
            if (this.node_is_method(e.f, *s)) {
                methods.append(line.as_str());
            } else {
                statics.append(line.as_str());
            }
        }
        out.append(this.lua_meta(sn.as_str(), methods.as_str()).as_str());
        out.append("    lua_pop(L, 1);\n    lua_newtable(L);\n");
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
        .TRAIT(i) => { return S("void"); }, // only the wide languages take traits (bind.wide)
        .LIST(x) => { return S("void"); }, // only the wide languages take lists (bind.wide)
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
    var b: bind = { c: this, pkg: pkg, wide: lang == "c" || lang == "cpp" || lang == "rust" || lang == "zig" || lang == "go" || lang == "python" || lang == "pyi" || lang == "java" || lang == "csharp" || lang == "node" || lang == "js" || lang == "ts" || lang == "lua" || lang == "json" };
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
        try b.py_check();
        return b.py_text();
    }
    if (lang == "pyi") {
        try b.py_check();
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
