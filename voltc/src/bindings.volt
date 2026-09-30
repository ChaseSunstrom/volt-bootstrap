// Bindings for other languages: `voltc bindings NAME --lang c|cpp|rust|zig|python` describes package
// NAME's export fns and the types they use, for programs that call a library built with
// `voltc lib NAME --shared` (or `--static`). Every type crosses as C sees it: numbers, bool,
// pointers (T* and T&), cstr, str (volt_str: a pointer and a length), structs whose fields cross,
// plain enums (their tag type), error sets (u32 codes), E!T (a struct of the error code and the
// value) and extern "C" fns. Anything else is an error naming the fn and the type.
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
                .CSTR => { return shape::CSTR; },
                .FN_PTR(ps, r, va) => { return this.shape_of(x); },
                default => { return this.no_form(t); },
            }
        },
        .ARRAY(elem, n) => {
            this.shape_of(elem) ?? return null;
            return shape::ARRAY(elem, n);
        },
        .STRUCT(s) => {
            if (has_u32(&this.structs, s) || has_u32(&this.visiting, s)) {
                return shape::STRUCT(s);
            }
            // its fields' structs are declared first (C needs them complete)
            put(&this.visiting, s);
            for (f&) in this.c.si(s).fields.items() {
                this.shape_of(f.ty) ?? return null;
            }
            this.visiting.pop();
            put(&this.structs, s);
            return shape::STRUCT(s);
        },
        .ENUM(e) => {
            val info = this.c.ei(e);
            if (info.is_error) {
                if (!has_u32(&this.codes, t)) {
                    put(&this.codes, t);
                }
                return shape::CODE;
            }
            if (info.has_payload) {
                return this.no_form(t);
            }
            if (!has_u32(&this.enums, e)) {
                put(&this.enums, e);
            }
            return shape::ENUM(e);
        },
        .ANYERR => { return shape::CODE; },
        .ERR_UNION(e, x) => {
            this.shape_of(e) ?? return null;
            this.shape_of(x) ?? return null;
            if (!has_u32(&this.results, t)) {
                put(&this.results, t);
            }
            return shape::RESULT(e, x);
        },
        .FN_PTR(ps, r, va) => {
            if (va) {
                return this.no_form(t);
            }
            for (p&) in ps.items() {
                this.shape_of(*p) ?? return null;
            }
            this.shape_of(r) ?? return null;
            for (i) in 0..this.fns.len {
                if (*this.fns.at(i) == t) {
                    return shape::FN(@cast<u32>(i));
                }
            }
            put(&this.fns, t);
            return shape::FN(@cast<u32>(this.fns.len - 1));
        },
        default => { return this.no_form(t); },
    }
}

attach fn pointer(this: bind&, x: u32) -> shape? {
    if (x != VOID) {
        this.shape_of(x) ?? return null;
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

// the short name of a type in bindings (a struct's or enum's own name, i32, f64...)
attach fn short(this: bind&, t: u32) -> std::string {
    match (*this.c.t.get(t)) {
        .STRUCT(s) => { return this.local(this.c.si(s).name); },
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

// ---------- C and C++ ----------

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
    }
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

// "T name" (with [N] after the name for arrays)
attach fn c_decl(this: bind&, t: u32, name: str, cpp: bool) -> std::string {
    var s = this.c_prim(t, cpp);
    if (!ends_with(s.as_str(), "*")) {
        s.push(' ');
    }
    s.append(name);
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

attach fn c_text(this: bind&, cpp: bool) -> std::string {
    val guard = upper(this.pkg);
    var out: std::string = {};
    out.append(fmt("// {}: generated by voltc bindings; the C interface of the Volt package\n", S(this.pkg)).as_str());
    out.append(fmt("// {} (build it with voltc lib NAME --shared or --static)\n", S(this.pkg)).as_str());
    if (cpp) {
        out.append("#pragma once\n#include <cstddef>\n#include <cstdint>\n#include <cstring>\n#include <string_view>\n\n");
        out.append(fmt("namespace {} {{\n\n", S(this.pkg)).as_str());
        if (this.uses_str) {
            out.append("// a Volt str: bytes and a length (no terminator)\nstruct str {\n    const uint8_t *ptr;\n    size_t len;\n    str(const char *s) : ptr((const uint8_t *)s), len(std::strlen(s)) {}\n    str(std::string_view s) : ptr((const uint8_t *)s.data()), len(s.size()) {}\n    std::string_view view() const { return {(const char *)ptr, len}; }\n};\n\n");
        }
    } else {
        out.append(fmt2("#ifndef {}_H\n#define {}_H\n#include <stdbool.h>\n#include <stddef.h>\n#include <stdint.h>\n\n#ifdef __cplusplus\nextern \"C\" {{\n#endif\n\n", copy guard, copy guard).as_str());
        if (this.uses_str) {
            out.append("#ifndef VOLT_STR_DEFINED\n#define VOLT_STR_DEFINED\n// a Volt str: bytes and a length (no terminator)\ntypedef struct {\n    const uint8_t *ptr;\n    size_t len;\n} volt_str;\n#endif\n\n");
        }
    }
    // declared up front, so pointers between structs work in any order
    for (s&) in this.structs.items() {
        val n = this.c_named(this.c.si(*s).name, cpp);
        if (cpp) {
            out.append(fmt("struct {};\n", copy n).as_str());
        } else {
            out.append(fmt2("typedef struct {} {};\n", copy n, copy n).as_str());
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
    for (s&) in this.structs.items() {
        val info = this.c.si(*s);
        out.append(fmt("\nstruct {} {{\n", this.c_named(info.name, cpp)).as_str());
        for (f&) in info.fields.items() {
            out.append(fmt("    {};\n", this.c_decl(f.ty, f.name, cpp)).as_str());
        }
        out.append("};\n");
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
    out.append("\n");
    if (cpp) {
        out.append("extern \"C\" {\n");
    }
    for (i&) in this.exports().items() {
        val f = this.c.fi(*i);
        var args: std::string = {};
        for (p&) in f.params.items() {
            if (args.len() > 0) {
                args.append(", ");
            }
            args.append(this.c_decl(p.ty, p.name, cpp).as_str());
        }
        if (f.params.len == 0) {
            args.append("void");
        }
        out.append(fmt3("{} {}({});\n", this.c_prim(f.ret, cpp), S(f.c_name), move args).as_str());
    }
    if (cpp) {
        out.append(fmt("}\n\n}  // namespace {}\n", S(this.pkg)).as_str());
    } else {
        out.append(fmt("\n#ifdef __cplusplus\n}\n#endif\n#endif // {}_H\n", copy guard).as_str());
    }
    return move out;
}

// ---------- Rust ----------

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
            var s = S("*mut ");
            s.append(this.rust_ty(x).as_str());
            return move s;
        },
        .STRUCT(s) => { return this.local(this.c.si(s).name); },
        .ENUM(e) => { return this.local(this.c.ei(e).name); },
        .CODE => { return S("u32"); },
        .RESULT(e, x) => { return this.result_name(t); },
        .ARRAY(elem, n) => { return fmt2("[{}; {}]", this.rust_ty(elem), unum(n)); },
        .FN(i) => {
            match (*this.c.t.get(t)) {
                .FN_PTR(ps, r, va) => {
                    var s = S("extern \"C\" fn(");
                    for (k) in 0..ps.len {
                        if (k > 0) {
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
                },
                default => { return S("()"); },
            }
        },
    }
}

attach fn rust_text(this: bind&) -> std::string {
    var out: std::string = {};
    out.append(fmt("// {}: generated by voltc bindings; the C interface of the Volt package, for Rust.\n", S(this.pkg)).as_str());
    out.append("// Link the library yourself (-l NAME, or #[link] in a build script): shared or static.\n");
    out.append("#![allow(non_camel_case_types, non_upper_case_globals, non_snake_case, dead_code)]\n");
    if (this.uses_str) {
        out.append("\n/// a Volt str: bytes and a length (no terminator)\n#[repr(C)]\n#[derive(Clone, Copy, Debug)]\npub struct VoltStr {\n    pub ptr: *const u8,\n    pub len: usize,\n}\n\nimpl VoltStr {\n    pub fn from(s: &str) -> VoltStr {\n        VoltStr { ptr: s.as_ptr(), len: s.len() }\n    }\n    /// the bytes (valid as long as what the str points into)\n    pub unsafe fn bytes<'a>(self) -> &'a [u8] {\n        std::slice::from_raw_parts(self.ptr, self.len)\n    }\n}\n");
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
    for (s&) in this.structs.items() {
        val info = this.c.si(*s);
        out.append(fmt("\n#[repr(C)]\n#[derive(Clone, Copy, Debug)]\npub struct {} {{\n", this.local(info.name)).as_str());
        for (f&) in info.fields.items() {
            out.append(fmt2("    pub {}: {},\n", S(f.name), this.rust_ty(f.ty)).as_str());
        }
        out.append("}\n");
    }
    for (rt&) in this.results.items() {
        match (*this.c.t.get(*rt)) {
            .ERR_UNION(e, x) => {
                out.append(fmt2("\n/// {}: error is 0, or the error's code\n#[repr(C)]\n#[derive(Clone, Copy, Debug)]\npub struct {} {{\n    pub error: u32,\n", this.c.ty_name(*rt), this.result_name(*rt)).as_str());
                if (x != VOID) {
                    out.append(fmt("    pub value: {},\n", this.rust_ty(x)).as_str());
                }
                out.append("}\n");
            },
            default => {},
        }
    }
    out.append("\nextern \"C\" {\n");
    for (i&) in this.exports().items() {
        val f = this.c.fi(*i);
        var args: std::string = {};
        for (p&) in f.params.items() {
            if (args.len() > 0) {
                args.append(", ");
            }
            args.append(fmt2("{}: {}", S(p.name), this.rust_ty(p.ty)).as_str());
        }
        var ret: std::string = {};
        if (f.ret != VOID) {
            ret = fmt(" -> {}", this.rust_ty(f.ret));
        }
        out.append(fmt3("    pub fn {}({}){};\n", S(f.c_name), move args, move ret).as_str());
    }
    out.append("}\n");
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
            var s = S("*");
            s.append(this.zig_ty(x).as_str());
            return move s;
        },
        .STRUCT(s) => { return this.local(this.c.si(s).name); },
        .ENUM(e) => { return this.local(this.c.ei(e).name); },
        .CODE => { return S("u32"); },
        .RESULT(e, x) => { return this.result_name(t); },
        .ARRAY(elem, n) => { return fmt2("[{}]{}", unum(n), this.zig_ty(elem)); },
        .FN(i) => {
            match (*this.c.t.get(t)) {
                .FN_PTR(ps, r, va) => {
                    var s = S("*const fn (");
                    for (k) in 0..ps.len {
                        if (k > 0) {
                            s.append(", ");
                        }
                        s.append(this.zig_ty(*ps.at(k)).as_str());
                    }
                    s.append(") callconv(.c) ");
                    s.append(this.zig_ty(r).as_str());
                    return move s;
                },
                default => { return S("void"); },
            }
        },
    }
}

attach fn zig_text(this: bind&) -> std::string {
    var out: std::string = {};
    out.append(fmt("// {}: generated by voltc bindings; the C interface of the Volt package, for Zig.\n", S(this.pkg)).as_str());
    if (this.uses_str) {
        out.append("\n/// a Volt str: bytes and a length (no terminator)\npub const VoltStr = extern struct {\n    ptr: [*]const u8,\n    len: usize,\n    pub fn from(s: []const u8) VoltStr {\n        return .{ .ptr = s.ptr, .len = s.len };\n    }\n};\n");
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
    out.append("\n");
    for (i&) in this.exports().items() {
        val f = this.c.fi(*i);
        var args: std::string = {};
        for (p&) in f.params.items() {
            if (args.len() > 0) {
                args.append(", ");
            }
            args.append(fmt2("{}: {}", S(p.name), this.zig_ty(p.ty)).as_str());
        }
        out.append(fmt3("pub extern fn {}({}) {};\n", S(f.c_name), move args, this.zig_ty(f.ret)).as_str());
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
        .FN(i) => {
            match (*this.c.t.get(t)) {
                .FN_PTR(ps, r, va) => {
                    var s = S("ctypes.CFUNCTYPE(");
                    s.append(this.py_ty(r).as_str());
                    for (p&) in ps.items() {
                        s.append(", ");
                        s.append(this.py_ty(*p).as_str());
                    }
                    s.push(')');
                    return move s;
                },
                default => { return S("None"); },
            }
        },
    }
}

attach fn py_text(this: bind&) -> std::string {
    var out: std::string = {};
    out.append(fmt("# {}: generated by voltc bindings; the C interface of the Volt package, for Python\n", S(this.pkg)).as_str());
    out.append(fmt2("# (ctypes). It loads lib{}.so from $VOLT_{}_LIB, else from next to this file.\n", S(this.pkg), upper(this.pkg)).as_str());
    out.append("import ctypes\nimport os\n\n");
    out.append(fmt2("_lib = ctypes.CDLL(os.environ.get(\"VOLT_{}_LIB\") or os.path.join(os.path.dirname(os.path.abspath(__file__)), \"lib{}.so\"))\n", upper(this.pkg), S(this.pkg)).as_str());
    if (this.uses_str) {
        out.append("\n\nclass VoltStr(ctypes.Structure):\n    \"\"\"a Volt str: bytes and a length (no terminator)\"\"\"\n    _fields_ = [(\"ptr\", ctypes.c_void_p), (\"len\", ctypes.c_size_t)]\n\n    def __str__(self):\n        return ctypes.string_at(self.ptr, self.len).decode()\n\n\ndef _str(s):\n    b = s.encode() if isinstance(s, str) else bytes(s)\n    v = VoltStr(ctypes.cast(ctypes.c_char_p(b), ctypes.c_void_p), len(b))\n    v._keep = b\n    return v\n");
    }
    for (e&) in this.enums.items() {
        val info = this.c.ei(*e);
        out.append(fmt("\n\nclass {}:\n", this.local(info.name)).as_str());
        for (i) in 0..info.names.len {
            out.append(fmt2("    {} = {}\n", S(*info.names.at(i)), num(*info.values.at(i))).as_str());
        }
    }
    for (et&) in this.codes.items() {
        match (*this.c.t.get(*et)) {
            .ENUM(e) => {
                val info = this.c.ei(e);
                out.append(fmt2("\n\nclass {}:\n    \"\"\"the codes of error set {} (0 means no error)\"\"\"\n", this.local(info.name), S(info.name)).as_str());
                for (i) in 0..info.names.len {
                    out.append(fmt2("    {} = {}\n", S(*info.names.at(i)), num(*info.values.at(i))).as_str());
                }
            },
            default => {},
        }
    }
    // the classes first, then their fields: structs may point at each other
    for (s&) in this.structs.items() {
        out.append(fmt("\n\nclass {}(ctypes.Structure):\n    pass\n", this.local(this.c.si(*s).name)).as_str());
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
    for (i&) in this.exports().items() {
        val f = this.c.fi(*i);
        var types: std::string = {};
        var names: std::string = {};
        var conv: std::string = {};
        for (p&) in f.params.items() {
            if (names.len() > 0) {
                names.append(", ");
                types.append(", ");
                conv.append(", ");
            }
            names.append(p.name);
            types.append(this.py_ty(p.ty).as_str());
            val sh = this.shape_of(p.ty) ?? shape::VOID;
            match (sh) {
                .STR => { conv.append(fmt("_str({})", S(p.name)).as_str()); },
                .CSTR => { conv.append(fmt3("({}.encode() if isinstance({}, str) else {})", S(p.name), S(p.name), S(p.name)).as_str()); },
                .PTR(x) => {
                    // a structure by reference (or a pointer as it is)
                    conv.append(fmt3("(ctypes.byref({}) if isinstance({}, ctypes.Structure) else {})", S(p.name), S(p.name), S(p.name)).as_str());
                },
                default => { conv.append(p.name); },
            }
        }
        out.append(fmt2("\n\n_lib.{}.argtypes = [{}]\n", S(f.c_name), move types).as_str());
        out.append(fmt2("_lib.{}.restype = {}\n", S(f.c_name), this.py_ty(f.ret)).as_str());
        var call = fmt2("_lib.{}({})", S(f.c_name), move conv);
        val rs = this.shape_of(f.ret) ?? shape::VOID;
        match (rs) {
            .STR => { call = fmt("str({})", move call); },
            .CSTR => { call = fmt("(lambda r: r.decode() if r is not None else None)({})", move call); },
            default => {},
        }
        out.append(fmt3("\n\ndef {}({}):\n    return {}\n", S(f.c_name), move names, move call).as_str());
    }
    return move out;
}

// ---------- the command ----------

// "WHAT is T, which has no C form" (naming the part of T that doesn't cross, when that's inside it)
attach fn no_c_form(this: bind&, at: span, what: std::string, t: u32) -> compile_error {
    var msg = fmt2("{} is {}, which has no C form", move what, this.c.ty_name(t));
    if (this.bad != t) {
        msg.append(fmt(" (because of the {} in it)", this.c.ty_name(this.bad)).as_str());
    }
    return with_help(fail(at, move msg), S("bindings take numbers, bool, pointers and references, cstr, str, structs of those, plain enums, error sets, E!T and extern \"C\" fns"));
}

// the bindings of package pkg in lang (c, cpp, rust, zig, python)
attach fn bindings(this: checker&, pkg: str, lang: str) -> compile_error!std::string {
    var b: bind = { c: this, pkg: pkg };
    val fns = b.exports();
    if (fns.len == 0) {
        return fail(NO_SPAN, fmt("package {} has no export fns to make bindings for", S(pkg)));
    }
    // every type each fn uses has to cross
    for (i&) in fns.items() {
        val f = this.fi(*i);
        val at = this.dl(f.decl).item.span;
        for (p&) in f.params.items() {
            if (b.shape_of(p.ty) == null) {
                return b.no_c_form(at, fmt2("export fn {}: its parameter {}", S(f.name), S(p.name)), p.ty);
            }
        }
        if (b.shape_of(f.ret) == null) {
            return b.no_c_form(at, fmt("export fn {}: its return type", S(f.name)), f.ret);
        }
    }
    if (lang == "c") {
        return b.c_text(false);
    }
    if (lang == "cpp") {
        return b.c_text(true);
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
    return fail(NO_SPAN, fmt("--lang takes c, cpp, rust, zig or python, not '{}'", S(lang)));
}
