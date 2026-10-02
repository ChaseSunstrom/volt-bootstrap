// The C backend: IR (ir.volt) to one C unit, with the runtime prelude in front. Types come from the
// checker's tables; everything else from the IR. Locals are declared at the top of their function
// (a DECL is its first assignment), so jumps never cross a declaration.
use std::mem;

// state for emitting one C unit from the checker's IR
struct cgen {
    c: checker&;
    tnames: std::map<u32, str> = {};  // type id -> C type name
    used_tys: std::vec<u32> = {};     // every type named so far (their definitions follow)
    // defined: types already emitted (or being emitted); fwd: their forward typedefs; defs: their
    // struct bodies, each after the types it holds by value
    defined: std::map<u32, bool> = {};
    fwd: std::string = {};
    defs: std::string = {};
    locals: std::vec<str> = {};       // C names of the current fn's locals
    globals: std::map<str, bool> = {}; // file-scope C names, which locals avoid (global_names)
    // fn_idx: the fn whose body is being written; tmp: its fresh() counter
    fn_idx: u32 = 0;
    tmp: u32 = 0;
    // statements go one per line at depth (4 spaces each), except inside a statement expression
    // (inline > 0), which stays on one line
    depth: usize = 0;
    inline: u32 = 0;
    // the labels some goto in the current fn jumps to (the others aren't printed)
    targets: std::map<u32, bool> = {};
    // struct members go one per line at this depth (2 inside a union)
    mdepth: usize = 1;
    // --profiler: the Volt line the statements being written come from (0: none yet in this fn); each
    // C statement gets it again, since one Volt statement can be several lines of C
    at_file: u32 = 0;
    at_line: u32 = 0;
}

fn int_c(k: int_ty) -> str {
    match (k) {
        .I8 => { return "int8_t"; },
        .I16 => { return "int16_t"; },
        .I32 => { return "int32_t"; },
        .I64 => { return "int64_t"; },
        .I128 => { return "__int128"; },
        .ISIZE => { return "ptrdiff_t"; },
        .U8 => { return "uint8_t"; },
        .U16 => { return "uint16_t"; },
        .U32 => { return "uint32_t"; },
        .U64 => { return "uint64_t"; },
        .U128 => { return "unsigned __int128"; },
        .USIZE => { return "size_t"; },
    }
}

// the unsigned C type wrapping arithmetic is done in (at least unsigned int, so no promotion to int)
fn int_wrap_c(k: int_ty) -> str {
    val b = k.bits();
    if (b <= 32) {
        return "uint32_t";
    }
    if (b == 64) {
        return "uint64_t";
    }
    return "unsigned __int128";
}

// n itself, or "" when n is a C keyword (put_member prefixes those with volt_kw_)
fn c_member(n: str) -> str {
    val kw: str[49] = { "auto", "break", "case", "char", "const", "continue", "default", "do", "double", "else", "enum", "extern", "float", "for", "goto", "if", "inline", "int", "long", "register", "restrict", "return", "short", "signed", "sizeof", "static", "struct", "switch", "typedef", "union", "unsigned", "void", "volatile", "while", "_Alignas", "_Alignof", "_Atomic", "_Bool", "_Complex", "_Generic", "_Imaginary", "_Noreturn", "_Static_assert", "_Thread_local", "asm", "typeof", "bool", "true", "false" };
    for (k) in kw {
        if (k == n) {
            return "";
        }
    }
    return n;
}

// n as a C member name, renamed volt_kw_n when it is a C keyword
attach fn put_member(this: cgen&, out: std::string&, n: str) -> void {
    if (c_member(n).len == 0) {
        out.append("volt_kw_");
    }
    out.append(n);
}

// C string literal using octal escapes (hex escapes in C swallow following hex digits)
fn put_c_str(out: std::string&, s: str) -> void {
    out.push('"');
    for (b) in s {
        if (b == '"') {
            out.append("\\\"");
        } else if (b == '\\') {
            out.append("\\\\");
        } else if (b == '?') {
            out.append("\\?"); // no trigraphs
        } else if (b >= 32 && b <= 126) {
            out.push(b);
        } else if (b == '\n') {
            out.append("\\n");
        } else if (b == '\t') {
            out.append("\\t");
        } else if (b == '\r') {
            out.append("\\r");
        } else {
            out.push('\\');
            out.push('0' + ((b >> 6) & 7));
            out.push('0' + ((b >> 3) & 7));
            out.push('0' + (b & 7));
        }
    }
    out.push('"');
}

// ---------- types ----------

// the C name of type t, made once and cached; naming a type queues it in used_tys so type_defs defines it
attach fn ty(this: cgen&, t: u32) -> str {
    val have = this.tnames.get(t);
    if (have) {
        return *have;
    }
    var name: std::string = {};
    match (*this.c.t.get(t)) {
        .VOID => { name.append("void"); },
        .NEVER => { name.append("void"); },
        .TYPE => { name.append("void"); },
        .BOOL => { name.append("bool"); },
        .NULL => { name.append("void*"); },
        .VOIDPTR => { name.append("void*"); },
        .STR => { name.append("volt_str"); },
        .CSTR => { name.append("const char*"); },
        .FLOAT(b) => {
            if (b == 16) {
                name.append("_Float16");
            } else if (b == 32) {
                name.append("float");
            } else if (b == 64) {
                name.append("double");
            } else {
                name.append("__float128");
            }
        },
        .INT(k) => { name.append(int_c(k)); },
        .REF(x) => {
            name.append(this.ty(x));
            name.push('*');
        },
        .PTR(x) => {
            name.append(this.ty(x));
            name.push('*');
        },
        .OPT(x) => {
            if (this.c.niche(x)) {
                name.append(this.ty(x));
            } else {
                name.append("volt_t");
                name.append_uint(@cast<u64>(t));
            }
        },
        .STRUCT(s) => { name.append(this.c.si(s).c_name); },
        .ENUM(e) => {
            val info = this.c.ei(e);
            if (info.has_payload) {
                name.append(info.c_name);
            } else {
                name.append(int_c(info.tag));
            }
        },
        .ANYERR => { name.append("uint32_t"); },
        .TRAIT_UNION(u) => { name.append(this.c.ui(u).c_name); },
        .CLOSURE(x) => { name.append(this.c.ci(x).c_name); },
        default => {
            name.append("volt_t");
            name.append_uint(@cast<u64>(t));
        },
    }
    val n = this.c.intern(move name);
    this.tnames.put(t, n);
    put(&this.used_tys, t);
    return n;
}

// does this type get a C definition of ours?
attach fn needs_def(this: cgen&, t: u32) -> bool {
    match (*this.c.t.get(t)) {
        .OPT(x) => { return !this.c.niche(x); },
        .STRUCT(s) => { return !this.c.header_struct(s); },
        .ENUM(e) => { return this.c.ei(e).has_payload; },
        .ARRAY(x, n) => { return true; },
        .SLICE(x) => { return true; },
        .TUPLE(ts, names) => { return true; },
        .RANGE(x) => { return true; },
        .FN_PTR(ps, r, va) => { return true; },
        .ERR_UNION(e, x) => { return true; },
        .TRAIT_UNION(u) => { return true; },
        .CLOSURE(c) => { return true; },
        .FN_VAL(ps, r) => { return true; },
        .FRAME(i) => { return true; },
        default => { return false; },
    }
}

// types that must be complete before this one can be defined
attach fn value_deps(this: cgen&, t: u32) -> std::vec<u32> {
    var out: std::vec<u32> = {};
    match (*this.c.t.get(t)) {
        .OPT(x) => { put(&out, x); },
        .ARRAY(x, n) => { put(&out, x); },
        .RANGE(x) => { put(&out, x); },
        .TUPLE(ts, names) => { out = copy ts; },
        // a function pointer typedef names its parameter and result types, which may be typedefs
        // too (other function pointers)
        .FN_PTR(ps, r, va) => {
            out = copy ps;
            put(&out, r);
        },
        .FN_VAL(ps, r) => {
            out = copy ps;
            put(&out, r);
        },
        .STRUCT(s) => {
            val fs = this.c.struct_fields(s, {}) catch |e| { return {}; };
            for (f&) in fs.items() {
                put(&out, f.ty);
            }
        },
        .ENUM(e) => {
            val ps = this.c.enum_payloads(e, {}) catch |x| { return {}; };
            for (p&) in ps.items() {
                if (*p) {
                    put(&out, *p ?? 0);
                }
            }
        },
        .ERR_UNION(e, x) => {
            put(&out, e);
            put(&out, x);
        },
        .TRAIT_UNION(u) => { out = copy this.c.ui(u).members; },
        .CLOSURE(c) => {
            for (cp&) in this.c.ci(c).caps.items() {
                put(&out, cp.ty);
            }
        },
        .FRAME(i) => {
            put(&out, this.c.fi(i).ret);
            for (f&) in this.c.frame_of(i).fields.items() {
                put(&out, f.ty);
            }
        },
        default => {},
    }
    return move out;
}

// " T name;" (nothing for a void member)
attach fn member(this: cgen&, body: std::string&, t: u32, name: str) -> void {
    if (t == VOID || t == NEVER) {
        return;
    }
    body.push('\n');
    push_n(body, ' ', this.mdepth * 4);
    body.append(this.ty(t));
    body.push(' ');
    this.put_member(body, name);
    body.push(';');
}

attach fn member_n(this: cgen&, body: std::string&, t: u32, prefix: str, i: usize) -> void {
    var n = S(prefix);
    n.append_uint(@cast<u64>(i));
    this.member(body, t, this.c.intern(move n));
}

// a function type's C declarator around `inner`: R (*inner)(A, B, ...)
attach fn fn_decl(this: cgen&, out: std::string&, ret: u32, params: std::vec<u32>&, lead_env: bool, va: bool, inner: str) -> void {
    if (ret == NEVER) {
        out.append("void");
    } else {
        out.append(this.ty(ret));
    }
    out.append(" (*");
    out.append(inner);
    out.append(")(");
    var first = true;
    if (lead_env) {
        out.append("void*");
        first = false;
    }
    for (p&) in params.items() {
        if (*p == VOID) {
            continue;
        }
        if (!first) {
            out.append(", ");
        }
        out.append(this.ty(*p));
        first = false;
    }
    if (va) {
        out.append(", ...");
    } else if (first) {
        out.append("void");
    }
    out.push(')');
}

// emits t's forward typedef and struct definition, after defining the types it holds by value;
// a fn pointer type is a plain typedef instead. Each type is defined once
attach fn define(this: cgen&, t: u32) -> void {
    if (this.defined.get(t) != null) {
        return;
    }
    this.defined.put(t, true);
    for (d&) in this.value_deps(t).items() {
        this.ty(*d);
        // a niche optional is its payload's C type (a function pointer's typedef, say)
        var dep = *d;
        match (*this.c.t.get(dep)) {
            .OPT(x) => {
                if (this.c.niche(x)) {
                    dep = x;
                }
            },
            default => {},
        }
        if (this.needs_def(dep)) {
            this.define(dep);
        }
    }
    val name = this.ty(t);
    var body: std::string = {};
    match (*this.c.t.get(t)) {
        .FN_PTR(ps, r, va) => {
            val xs = copy ps;
            var d = S("typedef ");
            this.fn_decl(&d, r, &xs, false, va, name);
            d.append(";\n");
            this.defs.append(d.as_str());
            return;
        },
        .FN_VAL(ps, r) => {
            val xs = copy ps;
            body.append("\n    ");
            this.fn_decl(&body, r, &xs, true, false, "fn");
            body.append(";\n    void* env;");
        },
        .CLOSURE(c) => {
            val caps = copy this.c.ci(c).caps;
            if (caps.len == 0) {
                body.append("\n    char unused;");
            }
            for (cp&) in caps.items() {
                this.member(&body, cp.ty, cp.name);
            }
        },
        .OPT(x) => {
            this.member(&body, x, "v");
            body.append("\n    bool has;");
        },
        .ARRAY(x, n) => {
            body.append("\n    ");
            body.append(this.ty(x));
            body.append(" a[");
            body.append_uint(n);
            body.append("];");
        },
        .SLICE(x) => {
            body.append("\n    ");
            body.append(this.ty(x));
            body.append("* ptr;\n    size_t len;");
        },
        .RANGE(x) => {
            this.member(&body, x, "lo");
            this.member(&body, x, "hi");
        },
        .TUPLE(ts, names) => {
            val xs = copy ts;
            for (i) in 0..xs.len {
                this.member_n(&body, *xs.at(i), "f", i);
            }
        },
        .STRUCT(s) => {
            val fs = this.c.struct_fields(s, {}) catch |e| { return; };
            val xs = copy *fs;
            for (f&) in xs.items() {
                this.member(&body, f.ty, f.name);
            }
        },
        .ENUM(e) => {
            val ps = copy *(this.c.enum_payloads(e, {}) catch |x| { return; });
            body.append("\n    ");
            body.append(int_c(this.c.ei(e).tag));
            body.append(" tag;\n    union {");
            this.mdepth = 2;
            for (i) in 0..ps.len {
                val p = *ps.at(i);
                if (p) {
                    this.member_n(&body, p, "v", i);
                }
            }
            this.mdepth = 1;
            body.append("\n    } u;");
        },
        .ERR_UNION(e, x) => {
            this.member(&body, e, "err");
            this.member(&body, x, "v");
        },
        .FRAME(i) => {
            body.append("\n    uint32_t state;\n    bool cancel;");
            this.member(&body, this.c.fi(i).ret, "ret");
            val fields = copy this.c.frame_of(i).fields;
            for (f&) in fields.items() {
                this.member(&body, f.ty, f.name);
            }
        },
        .TRAIT_UNION(u) => {
            val ms = copy this.c.ui(u).members;
            body.append("\n    uint16_t tag;\n    union {");
            this.mdepth = 2;
            for (i) in 0..ms.len {
                this.member_n(&body, *ms.at(i), "m", i);
            }
            this.mdepth = 1;
            body.append("\n    } u;");
        },
        default => { return; },
    }
    this.fwd.append("typedef struct ");
    this.fwd.append(name);
    this.fwd.push(' ');
    this.fwd.append(name);
    this.fwd.append(";\n");
    this.defs.append("\nstruct ");
    this.defs.append(name);
    this.defs.append(" {");
    this.defs.append(body.as_str());
    this.defs.append("\n};\n");
}

// definitions for every type named so far (naming one may name more)
attach fn type_defs(this: cgen&) -> void {
    var i: usize = 0;
    while (i < this.used_tys.len) {
        val t = *this.used_tys.at(i);
        i += 1;
        if (this.needs_def(t)) {
            this.define(t);
        }
    }
}

// ---------- names ----------

// is member i of agg padding a C struct's own members fill (clang.volt's pad_fields)?
attach fn is_padding(this: cgen&, agg: u32, i: u32) -> bool {
    match (*this.c.t.get(agg)) {
        .STRUCT(s) => {
            val fs = this.c.struct_fields(s, {}) catch |e| {
                return false;
            };
            val n = fs.at(@cast<usize>(i)).name;
            return n.len > 0 && n[0] == '@';
        },
        default => { return false; },
    }
}

// the C member for field i of agg, by ir.volt's numbering (enum payloads and trait union members
// live in the union `u`)
attach fn member_name(this: cgen&, out: std::string&, agg: u32, i: u32) -> void {
    match (*this.c.t.get(agg)) {
        .STRUCT(s) => {
            val fs = this.c.struct_fields(s, {}) catch |e| {
                out.append("?");
                return;
            };
            this.put_member(out, fs.at(@cast<usize>(i)).name);
        },
        .TUPLE(ts, names) => {
            out.push('f');
            out.append_uint(@cast<u64>(i));
        },
        .CLOSURE(c) => { this.put_member(out, this.c.ci(c).caps.at(@cast<usize>(i)).name); },
        .OPT(x) => {
            if (this.c.niche_field(x) != null) {
                this.member_name(out, x, i); // the owning struct itself
            } else if (i == 0) {
                out.push('v');
            } else {
                out.append("has");
            }
        },
        .SLICE(x) => {
            if (i == 0) {
                out.append("ptr");
            } else {
                out.append("len");
            }
        },
        .STR => {
            if (i == 0) {
                out.append("ptr");
            } else {
                out.append("len");
            }
        },
        .RANGE(x) => {
            if (i == 0) {
                out.append("lo");
            } else {
                out.append("hi");
            }
        },
        .ERR_UNION(e, x) => {
            if (i == 0) {
                out.append("err");
            } else {
                out.push('v');
            }
        },
        .ENUM(e) => {
            if (i == 0) {
                out.append("tag");
            } else {
                out.append("u.v");
                out.append_uint(@cast<u64>(i - 1));
            }
        },
        .TRAIT_UNION(u) => {
            if (i == 0) {
                out.append("tag");
            } else {
                out.append("u.m");
                out.append_uint(@cast<u64>(i - 1));
            }
        },
        .FN_VAL(ps, r) => {
            if (i == 0) {
                out.append("fn");
            } else {
                out.append("env");
            }
        },
        .FRAME(f) => {
            if (i == 0) {
                out.append("state");
            } else if (i == 1) {
                out.append("cancel");
            } else if (i == 2) {
                out.append("ret");
            } else {
                out.append(this.c.frame_of(f).fields.at(@cast<usize>(i - 3)).name);
            }
        },
        default => { out.append("?"); },
    }
}

// the member's type, for casts in initializers
attach fn member_ty(this: cgen&, agg: u32, i: u32) -> u32 {
    return this.c.field_ty(agg, i);
}

// is this a C scalar (so a cast converts it)?
attach fn scalar(this: cgen&, t: u32) -> bool {
    match (*this.c.t.get(t)) {
        .BOOL => { return true; },
        .NULL => { return true; },
        .VOIDPTR => { return true; },
        .CSTR => { return true; },
        .FLOAT(b) => { return true; },
        .INT(k) => { return true; },
        .REF(x) => { return true; },
        .PTR(x) => { return true; },
        .OPT(x) => { return this.c.t.is_niche(x); },
        .ENUM(e) => { return !this.c.ei(e).has_payload; },
        .ANYERR => { return true; },
        .FN_PTR(ps, r, va) => { return true; },
        default => { return false; },
    }
}

// ---------- expressions ----------

// an integer literal cast to t; 128-bit values are built from two 64-bit halves and INT64_MIN is
// spelled as an expression, since C has no literal for either
// an integer literal of type t, as plainly as C allows: 42 for an i32, 42u, 42LL, 42ULL, or (T)42
attach fn int_lit(this: cgen&, out: std::string&, v: i128, t: u32) -> void {
    var k = int_ty::I64;
    var is_int = false;
    var plain = false; // an int, not an enum or error code: its type follows from the suffix
    match (*this.c.t.get(t)) {
        .INT(x) => {
            k = x;
            is_int = true;
            plain = true;
        },
        .ENUM(e) => {
            k = this.c.ei(e).tag;
            is_int = true;
        },
        .ANYERR => {
            k = int_ty::U32;
            is_int = true;
        },
        default => {},
    }
    if (!is_int) {
        // a float (or bool) holding an integer value
        out.append("((");
        out.append(this.ty(t));
        out.append(")");
        if (v < 0) {
            out.append("(-");
            out.append_uint(@cast<u64>(-v));
            out.append(".0)");
        } else {
            out.append_uint(@cast<u64>(v));
            out.append(".0");
        }
        out.push(')');
        return;
    }
    if (k.bits() == 128) {
        val u = @cast<u128>(v);
        out.append("((");
        out.append(this.ty(t));
        out.append(")(((unsigned __int128)");
        out.append_uint(@cast<u64>(u >> 64));
        out.append("ULL << 64) | ");
        out.append_uint(@cast<u64>(u & 18446744073709551615));
        out.append("ULL))");
        return;
    }
    if (plain && k == int_ty::I32) {
        if (v == -2147483648) {
            out.append("(-2147483647 - 1)");
        } else if (v < 0) {
            out.append("(-");
            out.append_uint(@cast<u64>(-v));
            out.push(')');
        } else {
            out.append_uint(@cast<u64>(v));
        }
        return;
    }
    if (plain && k == int_ty::U32) {
        out.append_uint(@cast<u64>(v));
        out.push('u');
        return;
    }
    if (plain && k == int_ty::I64) {
        if (v == -9223372036854775807 - 1) {
            out.append("(-9223372036854775807LL - 1)");
        } else if (v < 0) {
            out.append("(-");
            out.append_uint(@cast<u64>(-v));
            out.append("LL)");
        } else {
            out.append_uint(@cast<u64>(v));
            out.append("LL");
        }
        return;
    }
    if (plain && k == int_ty::U64) {
        out.append_uint(@cast<u64>(v));
        out.append("ULL");
        return;
    }
    // (T)N; a value past what long long holds keeps its ULL
    out.push('(');
    out.append(this.ty(t));
    out.push(')');
    if (v == -9223372036854775807 - 1) {
        out.append("(-9223372036854775807LL - 1)");
    } else if (v < 0) {
        out.push('-');
        out.append_uint(@cast<u64>(-v));
    } else {
        out.append_uint(@cast<u64>(v));
        if (v > 9223372036854775807) {
            out.append("ULL");
        }
    }
}

extern "C" fn snprintf(buf: u8*, n: usize, f: cstr, ...) -> i32;

// a float literal cast to t; NaN and infinities come from builtins since C has no literal for them
attach fn float_lit(this: cgen&, out: std::string&, v: f64, t: u32) -> void {
    out.append("((");
    out.append(this.ty(t));
    out.append(")(");
    if (v != v) {
        out.append("__builtin_nan(\"\")");
    } else if (v > 1.7976931348623157e308 || v < -1.7976931348623157e308) {
        if (v < 0.0) {
            out.push('-');
        }
        out.append("__builtin_inf()");
    } else {
        // the shortest text that reads back as the same double
        var buf: u8[64];
        var n: i32 = 0;
        for (p) in 1..18 {
            n = snprintf(&buf[0], 64, "%.*g", @cast<i32>(p), v);
            if (strtod(@cast<cstr>(&buf[0]), null) == v) {
                break;
            }
        }
        val text = @cast<str>(@slice(&buf[0], @cast<usize>(n)));
        out.append(text);
        var has_point = false;
        for (b) in text {
            if (b == '.' || b == 'e' || b == 'n' || b == 'i') {
                has_point = true;
            }
        }
        if (!has_point) {
            out.append(".0");
        }
    }
    out.append("))");
}

attach fn local_name(this: cgen&, id: u32) -> str {
    return *this.locals.at(@cast<usize>(id));
}

// a temp name for this function: _cg7
attach fn fresh(this: cgen&) -> str {
    this.tmp += 1;
    var n = S("_cg");
    n.append_uint(@cast<u64>(this.tmp));
    return this.c.intern(move n);
}

attach fn is_null_node(this: cgen&, n: u32) -> bool {
    match (this.c.ir.at(n).kind) {
        .NULLPTR => { return true; },
        default => { return false; },
    }
}

// node n converted to type t where C wouldn't do it by itself: a cast when t is a different scalar type
// n as an operand. Every expression prints either as a primary, postfix or cast expression (a
// name, literal, call, member, element, (T)N) or inside its own parentheses, so none are needed here
attach fn operand(this: cgen&, out: std::string&, n: u32) -> void {
    this.expr(out, n);
}

// n as a whole expression (an argument, a right-hand side, a condition): its outer parentheses,
// if it has a pair around everything, left off
attach fn full(this: cgen&, out: std::string&, n: u32) -> void {
    var s: std::string = {};
    this.expr(&s, n);
    append_unwrapped(out, s.as_str());
}

attach fn full_as(this: cgen&, out: std::string&, n: u32, t: u32) -> void {
    var s: std::string = {};
    this.value_as(&s, n, t);
    append_unwrapped(out, s.as_str());
}

// s without a pair of parentheses around all of it (never a statement expression's: `({ ... })`
// needs them); string and char literals are skipped while matching
fn append_unwrapped(out: std::string&, s0: str) -> void {
    var s = s0;
    while (s.len >= 2 && s[0] == '(' && s[1] != '{' && matching_close(s) == s.len - 1) {
        s = s[1..s.len - 1];
    }
    out.append(s);
}

// the index of the ')' closing s[0]'s '(' (s.len when there's none)
fn matching_close(s: str) -> usize {
    var depth: usize = 0;
    var i: usize = 0;
    while (i < s.len) {
        val c = s[i];
        if (c == '"' || c == '\'') {
            // a literal: skip to its end
            i += 1;
            while (i < s.len && s[i] != c) {
                if (s[i] == '\\') {
                    i += 1;
                }
                i += 1;
            }
        } else if (c == '(') {
            depth += 1;
        } else if (c == ')') {
            depth -= 1;
            if (depth == 0) {
                return i;
            }
        }
        i += 1;
    }
    return s.len;
}

attach fn value_as(this: cgen&, out: std::string&, n: u32, t: u32) -> void {
    val nt = this.c.ir.ty_of(n);
    if (nt != t && t != VOID && this.scalar(t) && nt != NEVER) {
        out.append("((");
        out.append(this.ty(t));
        out.push(')');
        this.operand(out, n);
        out.push(')');
        return;
    }
    this.expr(out, n);
}

attach fn binop_sym(this: cgen&, op: binop_ir) -> str {
    match (op) {
        .ADD => { return "+"; },
        .SUB => { return "-"; },
        .MUL => { return "*"; },
        .DIV => { return "/"; },
        .REM => { return "%"; },
        .BITAND => { return "&"; },
        .BITOR => { return "|"; },
        .BITXOR => { return "^"; },
        .SHL => { return "<<"; },
        .SHR => { return ">>"; },
        .EQ => { return "=="; },
        .NE => { return "!="; },
        .LT => { return "<"; },
        .GT => { return ">"; },
        .LE => { return "<="; },
        .GE => { return ">="; },
        .AND => { return "&&"; },
        .OR => { return "||"; },
    }
}

attach fn is_place(this: cgen&, n: u32) -> bool {
    match (this.c.ir.at(n).kind) {
        .LOCAL(x) => { return true; },
        .GLOBAL(x) => { return true; },
        .FIELD(b, i) => { return true; },
        .DEREF(p) => { return true; },
        .INDEX(b, i) => { return true; },
        default => { return false; },
    }
}

// node n as a C expression; statements in value position become GNU statement expressions ({ ... })
attach fn expr(this: cgen&, out: std::string&, n: u32) -> void {
    val t = this.c.ir.ty_of(n);
    match (this.c.ir.at(n).kind) {
        .INT(v) => { this.int_lit(out, v, t); },
        .FLOAT(f) => { this.float_lit(out, f, t); },
        .BOOL(b) => {
            if (b) {
                out.append("true");
            } else {
                out.append("false");
            }
        },
        .STR(s) => {
            out.append("((volt_str){ (const uint8_t*)");
            put_c_str(out, s);
            out.append(", ");
            out.append_uint(@cast<u64>(s.len));
            out.append(" })");
        },
        .CSTR(s) => { put_c_str(out, s); },
        .NULLPTR => {
            out.append("((");
            out.append(this.ty(t));
            out.append(")0)");
        },
        .ZERO => {
            if (t == VOID || t == NEVER) {
                out.append("((void)0)");
            } else if (this.scalar(t)) {
                out.append("((");
                out.append(this.ty(t));
                out.append(")0)");
            } else {
                out.append("((");
                out.append(this.ty(t));
                out.append("){0})");
            }
        },
        .LOCAL(id) => {
            if (t == VOID) {
                out.append("((void)0)");
            } else {
                out.append(this.local_name(id));
            }
        },
        .GLOBAL(g) => { out.append(this.c.ir.globals.at(@cast<usize>(g)).name); },
        .FN(f) => { out.append(this.c.ir.fn_at(f).name); },
        .RT(name) => { out.append(name); },
        .FIELD(b, i) => {
            val bt = this.c.ir.ty_of(b);
            // a header struct's array field is a bare C array: view it as our array wrapper (same layout)
            var wrap = false;
            match (*this.c.t.get(bt)) {
                .STRUCT(s) => {
                    if (this.c.header_struct(s)) {
                        match (*this.c.t.get(t)) {
                            .ARRAY(x, n2) => { wrap = true; },
                            default => {},
                        }
                    }
                },
                default => {},
            }
            if (wrap) {
                out.append("(*(");
                out.append(this.ty(t));
                out.append("*)&");
            }
            match (this.c.ir.at(b).kind) {
                .DEREF(p) => {
                    this.operand(out, p);
                    out.append("->");
                },
                default => {
                    this.operand(out, b);
                    out.push('.');
                },
            }
            this.member_name(out, bt, i);
            if (wrap) {
                out.push(')');
            }
        },
        .DEREF(p) => {
            out.append("(*");
            this.operand(out, p);
            out.push(')');
        },
        .VLOAD(p) => {
            out.append("(*(volatile ");
            out.append(this.ty(this.c.ir.ty_of(n)));
            out.append("*)(");
            this.expr(out, p);
            out.append("))");
        },
        .VSTORE(p, v) => {
            out.append("(*(volatile ");
            out.append(this.ty(this.c.ir.ty_of(v)));
            out.append("*)(");
            this.expr(out, p);
            out.append(") = ");
            this.expr(out, v);
            out.push(')');
        },
        .ADDR(p) => {
            out.append("(&");
            this.expr(out, p);
            out.push(')');
        },
        .INDEX(b, i) => {
            // arrays are wrapper structs (member a); a cstr indexes as bytes
            val bt = this.c.ir.ty_of(b);
            match (*this.c.t.get(bt)) {
                .ARRAY(x, n2) => {
                    this.operand(out, b);
                    out.append(".a[");
                    this.full(out, i);
                    out.push(']');
                },
                .CSTR => {
                    out.append("((const uint8_t*)(");
                    this.expr(out, b);
                    out.append("))[");
                    this.expr(out, i);
                    out.push(']');
                },
                default => {
                    this.operand(out, b);
                    out.push('[');
                    this.full(out, i);
                    out.push(']');
                },
            }
        },
        .UNARY(op, x) => {
            match (op) {
                .NOT => {
                    out.append("(!");
                    this.expr(out, x);
                    out.push(')');
                },
                .BITNOT => {
                    out.append("((");
                    out.append(this.ty(t));
                    out.append(")~");
                    this.expr(out, x);
                    out.push(')');
                },
                .NEG => {
                    val k = this.c.t.int_of(t);
                    if (k) {
                        // wrapping: negate the unsigned form
                        out.append("((");
                        out.append(this.ty(t));
                        out.append(")(-(");
                        out.append(int_wrap_c(k));
                        out.append(")(");
                        this.expr(out, x);
                        out.append(")))");
                    } else {
                        out.append("(-");
                        this.expr(out, x);
                        out.push(')');
                    }
                },
            }
        },
        .BINARY(op, a, b) => { this.binary(out, op, a, b, t); },
        .CHECKED(op, a, b, loc) => {
            // volt_add_i32(a, b, "file:line:col"): the prelude's checked arithmetic
            out.append("volt_");
            match (op) {
                .SUB => { out.append("sub_"); },
                .MUL => { out.append("mul_"); },
                default => { out.append("add_"); },
            }
            val k = this.c.t.int_of(t) ?? int_ty::I64;
            out.append(k.name());
            out.push('(');
            this.full_as(out, a, t);
            out.append(", ");
            this.full_as(out, b, t);
            out.append(", ");
            put_c_str(out, loc);
            out.push(')');
        },
        .CONV(x) => {
            // to bool compares with zero instead of truncating
            if (t == BOOL && this.c.ir.ty_of(x) != BOOL) {
                out.append("((");
                this.expr(out, x);
                out.append(") != 0)");
            } else {
                out.append("((");
                out.append(this.ty(t));
                out.push(')');
                this.operand(out, x);
                out.push(')');
            }
        },
        .BITCAST(x) => {
            val xt = this.c.ir.ty_of(x);
            // same-class scalars convert with a cast; anything else goes through a union to keep the bits
            if (this.scalar(t) && this.scalar(xt) && this.c.t.is_float(t) == this.c.t.is_float(xt)) {
                out.append("((");
                out.append(this.ty(t));
                out.append(")(");
                this.expr(out, x);
                out.append("))");
            } else {
                out.append("(((union { ");
                out.append(this.ty(xt));
                out.append(" s; ");
                out.append(this.ty(t));
                out.append(" t; }){ .s = ");
                this.expr(out, x);
                out.append(" }).t)");
            }
        },
        .CALL(f, args&) => { this.call(out, f, args, t); },
        .AGG(inits) => {
            if (t == VOID || t == NEVER) {
                out.append("((void)0)");
                return;
            }
            // a compound literal with designated members; void members are left out and a fn value's fn slot
            // is cast to the pair's own signature
            out.append("((");
            out.append(this.ty(t));
            out.append("){ ");
            var first = true;
            for (fi&) in inits.items() {
                val mt = this.member_ty(t, fi.field);
                if (mt == VOID || mt == NEVER || this.is_padding(t, fi.field)) {
                    continue;
                }
                if (!first) {
                    out.append(", ");
                }
                first = false;
                out.push('.');
                this.member_name(out, t, fi.field);
                out.append(" = ");
                if (this.is_fn_slot(t, fi.field)) {
                    out.push('(');
                    match (*this.c.t.get(t)) {
                        .FN_VAL(ps, r) => {
                            val xs = copy ps;
                            this.fn_decl(out, r, &xs, true, false, "");
                        },
                        default => {},
                    }
                    out.push(')');
                    this.expr(out, fi.value);
                } else {
                    this.full_as(out, fi.value, mt);
                }
            }
            if (first) {
                out.append("})"); // no members: an empty initializer
                return;
            }
            out.append(" })");
        },
        .ARRAY_LIT(xs) => {
            val et = this.elem_of(t);
            out.append("((");
            out.append(this.ty(t));
            out.append("){ { ");
            for (i) in 0..xs.len {
                if (i > 0) {
                    out.append(", ");
                }
                this.full_as(out, *xs.at(i), et);
            }
            if (xs.len == 0) {
                out.push('0');
            }
            out.append(" } })");
        },
        .SEQ(stmts, v) => {
            out.append("({");
            this.inline += 1;
            for (s&) in stmts.items() {
                this.stmt(out, *s);
            }
            if (v) {
                this.nl(out);
                this.expr(out, v);
                out.push(';');
            }
            this.nl(out);
            this.inline -= 1;
            out.append("})");
        },
        .COND(c, a, b) => {
            out.push('(');
            this.operand(out, c);
            out.append(" ? ");
            this.full_as(out, a, t);
            out.append(" : ");
            this.full_as(out, b, t);
            out.push(')');
        },
        .SIZEOF(x) => {
            out.append("sizeof(");
            out.append(this.ty(x));
            out.push(')');
        },
        .ALIGNOF(x) => {
            out.append("_Alignof(");
            out.append(this.ty(x));
            out.push(')');
        },
        .OFFSETOF(x, i) => {
            out.append("__builtin_offsetof(");
            out.append(this.ty(x));
            out.append(", ");
            this.member_name(out, x, i);
            out.push(')');
        },
        default => {
            // a statement in value position (void)
            out.append("({");
            this.inline += 1;
            this.stmt(out, n);
            this.nl(out);
            this.inline -= 1;
            out.append("})");
        },
    }
}

// the fn slot of a fn(...) value, which holds a function of the pair's own signature
attach fn is_fn_slot(this: cgen&, t: u32, i: u32) -> bool {
    match (*this.c.t.get(t)) {
        .FN_VAL(ps, r) => { return i == 0; },
        default => { return false; },
    }
}

attach fn elem_of(this: cgen&, t: u32) -> u32 {
    match (*this.c.t.get(t)) {
        .ARRAY(x, n) => { return x; },
        default => { return VOID; },
    }
}

// a BINARY node with Volt's semantics in C: pointer arithmetic, wrapping int arithmetic, fmod for float REM
attach fn binary(this: cgen&, out: std::string&, op: binop_ir, a: u32, b: u32, t: u32) -> void {
    val at = this.c.ir.ty_of(a);
    val k = this.c.t.int_of(t);
    val wraps = op == binop_ir::ADD || op == binop_ir::SUB || op == binop_ir::MUL || op == binop_ir::SHL;
    var ptr_arith = false; // p - q counts elements, p + n steps by them: C's own pointer arithmetic
    match (*this.c.t.get(at)) {
        .PTR(x) => { ptr_arith = true; },
        .REF(x) => { ptr_arith = true; },
        default => {},
    }
    if (ptr_arith) {
        out.append("((");
        out.append(this.ty(t));
        out.append(")(");
        this.operand(out, a);
        out.push(' ');
        out.append(this.binop_sym(op));
        out.push(' ');
        this.operand(out, b);
        out.append("))");
        return;
    }
    if (k != null && wraps) {
        // ints wrap: compute in the unsigned form (C makes signed overflow and shifting negatives
        // left undefined)
        val kk = k ?? int_ty::I32;
        val ut = int_wrap_c(kk);
        out.append("((");
        out.append(this.ty(t));
        out.append(")((");
        out.append(ut);
        out.push(')');
        this.operand(out, a);
        out.push(' ');
        out.append(this.binop_sym(op));
        out.push(' ');
        if (op == binop_ir::SHL) {
            this.operand(out, b);
        } else {
            out.push('(');
            out.append(ut);
            out.push(')');
            this.operand(out, b);
        }
        out.append("))");
        return;
    }
    if (k != null && (op == binop_ir::BITAND || op == binop_ir::BITOR || op == binop_ir::BITXOR || op == binop_ir::DIV || op == binop_ir::REM || op == binop_ir::SHR)) {
        // these can't overflow (signed division is checked earlier in debug builds); C promotes small ints,
        // so cast the result back
        out.append("((");
        out.append(this.ty(t));
        out.append(")(");
        this.operand(out, a);
        out.push(' ');
        out.append(this.binop_sym(op));
        out.push(' ');
        this.operand(out, b);
        out.append("))");
        return;
    }
    if (this.c.t.is_float(t) && op == binop_ir::REM) {
        out.append("__builtin_fmod(");
        this.expr(out, a);
        out.append(", ");
        this.expr(out, b);
        out.push(')');
        return;
    }
    // comparisons, bool logic, float arithmetic; a pointer compared with null reads as pointer
    out.push('(');
    this.operand(out, a);
    out.push(' ');
    out.append(this.binop_sym(op));
    out.push(' ');
    if (this.is_null_node(b) && this.scalar(at)) {
        out.append("(");
        out.append(this.ty(at));
        out.append(")0");
    } else {
        this.operand(out, b);
    }
    out.push(')');
}

// a call; a direct callee (FN or RT) gets its args cast to the declared param types, a fn pointer is
// called as is, and a fn(...) value's fn slot is cast to a type built from the args (args[0] is the env)
// libm functions the C compiler knows as instructions (sqrtsd, roundsd...) when it sees them by name:
// called as __builtin_NAME, since Volt declares them under its own names
val BUILTIN_MATH: str[22] = { "sqrt", "sqrtf", "fabs", "fabsf", "floor", "floorf", "ceil", "ceilf", "trunc", "truncf", "round", "roundf", "rint", "rintf", "fma", "fmaf", "fmin", "fminf", "fmax", "fmaxf", "copysign", "copysignf" };

fn builtin_math(sym: str) -> str? {
    if (!starts_with(sym, "volt_ext_")) {
        return null;
    }
    val name = sym[9..sym.len];
    for (m) in BUILTIN_MATH {
        if (m == name) {
            return name;
        }
    }
    return null;
}

attach fn call(this: cgen&, out: std::string&, f: u32, args: std::vec<u32>&, t: u32) -> void {
    var direct = false;
    var params: std::vec<u32> = {};
    match (this.c.ir.at(f).kind) {
        .FN(i) => {
            direct = true;
            val sym = this.c.ir.fn_at(i).name;
            val m = builtin_math(sym);
            if (m) {
                out.append("__builtin_");
                out.append(m);
            } else {
                out.append(sym);
            }
            val fl = this.c.ir.fn_at(i);
            for (p&) in fl.params.items() {
                put(&params, fl.locals.at(@cast<usize>(*p)).ty);
            }
        },
        .RT(name) => {
            direct = true;
            out.append(name);
        },
        default => {},
    }
    if (!direct) {
        val ft = this.c.ir.ty_of(f);
        var typed = false;
        match (*this.c.t.get(ft)) {
            .FN_PTR(ps, r, va) => { typed = true; },
            default => {},
        }
        if (typed) {
            out.push('(');
            this.expr(out, f);
            out.push(')');
        } else {
            // a fn(...) value's fn slot: its type comes from the call itself
            var ats: std::vec<u32> = {};
            for (i) in 0..args.len {
                if (i > 0) {
                    put(&ats, this.c.ir.ty_of(*args.at(i)));
                }
            }
            out.append("((");
            this.fn_decl(out, t, &ats, true, false, "");
            out.append(")(");
            this.expr(out, f);
            out.append("))");
        }
    }
    out.push('(');
    var first = true;
    for (i) in 0..args.len {
        val a = *args.at(i);
        if (this.c.ir.ty_of(a) == VOID) {
            continue;
        }
        if (!first) {
            out.append(", ");
        }
        first = false;
        if (i < params.len) {
            this.full_as(out, a, *params.at(i));
        } else {
            this.full(out, a);
        }
    }
    out.push(')');
}

// ---------- statements ----------

// node n as C statements; a value whose type is void or never is evaluated only for its effects
// a new line at the current depth; inside a statement expression, a space
attach fn nl(this: cgen&, out: std::string&) -> void {
    if (this.inline > 0) {
        if (out.len() > 0 && *out.bytes.at(out.len() - 1) != ' ') {
            out.push(' ');
        }
        return;
    }
    out.push('\n');
    push_n(out, ' ', this.depth * 4);
}

// a statement's whole value that is a statement expression, ({ s; v }): s goes out as statements
// first and v is what's left (this runs s at the same point: before the rest of the statement)
attach fn hoist(this: cgen&, out: std::string&, n: u32) -> u32 {
    if (this.inline > 0) {
        return n;
    }
    match (this.c.ir.at(n).kind) {
        .SEQ(stmts, v) => {
            if (v) {
                for (s&) in stmts.items() {
                    this.stmt(out, *s);
                }
                return this.hoist(out, v);
            }
        },
        default => {},
    }
    return n;
}

// does `p = v` need v in a temp to be evaluated first? Only when the order shows: p isn't fixed
// and v changes memory, or p changes memory and v isn't a constant.
// ponytail: when both sides only fail checks (dst[i] = src[j]), which check reports first is C's choice
attach fn value_first(this: cgen&, p: u32, v: u32) -> bool {
    if (this.fixed_place(p)) {
        return false;
    }
    val va = this.acts(v);
    return (va & 1) != 0 || ((this.acts(p) & 1) != 0 && va != 0);
}

// a place whose address nothing in the statement can change: a local, a field of one, or what a
// local reference points at (a local whose address escaped and is reassigned by a call isn't caught)
attach fn fixed_place(this: cgen&, n: u32) -> bool {
    match (this.c.ir.at(n).kind) {
        .LOCAL(l) => { return true; },
        .FIELD(b, i) => { return this.fixed_place(b); },
        .DEREF(r) => {
            match (this.c.ir.at(r).kind) {
                .LOCAL(l) => { return true; },
                default => { return false; },
            }
        },
        default => { return false; },
    }
}

// what evaluating n can do, as bits: 1 change memory (a call that returns, an assignment), 2 stop
// the program (a failed check), 4 read memory
attach fn acts(this: cgen&, n: u32) -> u32 {
    var bits: u32 = 0;
    var todo = nodes(n);
    while (todo.len > 0) {
        val m = todo.pop() ?? 0;
        match (this.c.ir.at(m).kind) {
            .CALL(f, args) => {
                if (this.c.ir.ty_of(m) == NEVER) {
                    bits |= 2;
                } else {
                    bits |= 1;
                }
            },
            .ASSIGN(q, x) => { bits |= 1; },
            .VSTORE(q, x) => { bits |= 1; },
            .VLOAD(q) => { bits |= 5; },
            .CHECKED(op, a, b, loc) => { bits |= 2; },
            .LOCAL(l) => { bits |= 4; },
            .GLOBAL(g) => { bits |= 4; },
            .DEREF(q) => { bits |= 4; },
            .INDEX(b, i) => { bits |= 4; },
            default => {},
        }
        this.c.ir.kids(m, &todo);
    }
    return bits;
}

// statements nested one level deeper: the body of an if, a loop or a case
attach fn nested(this: cgen&, out: std::string&, n: u32) -> void {
    this.depth += 1;
    this.stmt(out, n);
    this.depth -= 1;
}

// one statement (or, for BLOCK and SEQ, several), each on its own line. Blocks don't need braces:
// every local is declared at the top of the function, and labels are the function's
// #line N "file": the C after it comes from that Volt line (--profiler builds' debug info)
fn line_directive(out: std::string&, file: str, line: u32) -> void {
    out.append("#line ");
    out.append_uint(@cast<u64>(line));
    out.append(" \"");
    for (ch) in file {
        if (ch == '\\' || ch == '"') {
            out.push('\\');
        }
        out.push(ch);
    }
    out.push('"');
}

attach fn stmt(this: cgen&, out: std::string&, n: u32) -> void {
    if (this.at_line > 0 && this.inline == 0) {
        match (this.c.ir.at(n).kind) {
            .AT(f, l) => {},
            .BLOCK(xs) => {},
            default => {
                out.push('\n');
                line_directive(out, this.c.files.at(@cast<usize>(this.at_file)).name, this.at_line);
            },
        }
    }
    match (this.c.ir.at(n).kind) {
        .DECL(l, init0) => {
            if (init0) {
                // a DECL only assigns: fn_body declared the local at the top of the fn
                val init = this.hoist(out, init0);
                val lt = this.c.ir.fn_at(this.fn_idx).locals.at(@cast<usize>(l)).ty;
                this.nl(out);
                if (lt == VOID || lt == NEVER || this.c.ir.ty_of(init) == NEVER) {
                    this.full(out, init);
                } else {
                    out.append(this.local_name(l));
                    out.append(" = ");
                    this.full_as(out, init, lt);
                }
                out.push(';');
            }
        },
        .ASSIGN(p, v0) => {
            val v = this.hoist(out, v0);
            this.nl(out);
            val pt = this.c.ir.ty_of(p);
            if (pt == VOID || pt == NEVER || this.c.ir.ty_of(v) == NEVER) {
                this.full(out, v);
            } else if (this.value_first(p, v)) {
                // C leaves the order of `p = v` open; Volt evaluates v first
                val tn = this.fresh();
                out.append("{ ");
                out.append(this.ty(pt));
                out.push(' ');
                out.append(tn);
                out.append(" = ");
                this.full_as(out, v, pt);
                out.append("; ");
                this.full(out, p);
                out.append(" = ");
                out.append(tn);
                out.append("; }");
                return;
            } else {
                this.full(out, p);
                out.append(" = ");
                this.full_as(out, v, pt);
            }
            out.push(';');
        },
        .IF(c0, a, b) => {
            val c = this.hoist(out, c0);
            this.nl(out);
            this.if_stmt(out, c, a, b);
        },
        .LOOP(b) => {
            this.nl(out);
            out.append("for (;;) {");
            this.nested(out, b);
            this.nl(out);
            out.push('}');
        },
        .LABEL(l) => {
            if (this.targets.get(l) == null) {
                return; // nothing jumps here
            }
            this.nl(out);
            out.append("volt_l");
            out.append_uint(@cast<u64>(l));
            out.append(":;");
        },
        .GOTO(l) => {
            this.nl(out);
            out.append("goto volt_l");
            out.append_uint(@cast<u64>(l));
            out.push(';');
        },
        .SWITCH(v, cases&, d) => {
            this.nl(out);
            this.switch_stmt(out, v, cases, d);
        },
        .RETURN(v0) => {
            var v = v0;
            if (v0) {
                v = this.hoist(out, v0);
            }
            this.nl(out);
            if (v) {
                val ret = this.c.ir.fn_at(this.fn_idx).ret;
                if (ret == VOID || ret == NEVER || this.c.ir.ty_of(v) == NEVER) {
                    this.full(out, v);
                    out.push(';');
                    this.nl(out);
                    out.append("return;");
                } else {
                    out.append("return ");
                    this.full_as(out, v, ret);
                    out.push(';');
                }
            } else {
                out.append("return;");
            }
        },
        .BLOCK(stmts) => {
            for (s&) in stmts.items() {
                this.stmt(out, *s);
            }
        },
        .UNREACHABLE => {
            this.nl(out);
            out.append("__builtin_unreachable();");
        },
        .AT(f, l) => {
            // the directive itself goes before each statement after this (not inside a ({ ... }),
            // which is written on one line)
            this.at_file = f;
            this.at_line = l;
        },
        .SEQ(stmts, v) => {
            for (s&) in stmts.items() {
                this.stmt(out, *s);
            }
            if (v) {
                this.nl(out);
                this.full(out, v);
                out.push(';');
            }
        },
        default => {
            this.nl(out);
            this.full(out, n);
            out.push(';');
        },
    }
}

// `if (c) { a } else { b }`, with `else if` for a chain
attach fn if_stmt(this: cgen&, out: std::string&, c: u32, a: u32, b: u32?) -> void {
    out.append("if (");
    this.full(out, c);
    out.append(") {");
    this.nested(out, a);
    this.nl(out);
    out.push('}');
    if (b) {
        val e = b;
        var inner = e;
        // a block holding just an if is an else-if
        match (this.c.ir.at(e).kind) {
            .BLOCK(xs) => {
                if (xs.len == 1) {
                    inner = *xs.at(0);
                }
            },
            default => {},
        }
        match (this.c.ir.at(inner).kind) {
            .IF(c2, a2, b2) => {
                out.append(" else ");
                this.if_stmt(out, c2, a2, b2);
                return;
            },
            default => {},
        }
        out.append(" else {");
        this.nested(out, e);
        this.nl(out);
        out.push('}');
    }
}

attach fn switch_stmt(this: cgen&, out: std::string&, v: u32, cases: std::vec<case_arm>&, d: u32?) -> void {
    val vt = this.c.ir.ty_of(v);
    var wide = false;
    val k = this.c.t.int_of(vt);
    if (k) {
        wide = k.bits() == 128;
    }
    match (*this.c.t.get(vt)) {
        .ENUM(e) => { wide = this.c.ei(e).tag.bits() == 128; },
        default => {},
    }
    if (wide) {
        // C can't switch on 128-bit ints: an if-chain on a temp
        val tn = this.fresh();
        out.append("{");
        this.depth += 1;
        this.nl(out);
        out.append(this.ty(vt));
        out.push(' ');
        out.append(tn);
        out.append(" = ");
        this.expr(out, v);
        out.push(';');
        this.nl(out);
        for (i) in 0..cases.len {
            if (i > 0) {
                out.append(" else ");
            }
            out.append("if (");
            out.append(tn);
            out.append(" == ");
            this.int_lit(out, cases.at(i).value, vt);
            out.append(") {");
            this.nested(out, cases.at(i).body);
            this.nl(out);
            out.push('}');
        }
        if (d) {
            if (cases.len > 0) {
                out.append(" else {");
            } else {
                out.push('{');
            }
            this.nested(out, d);
            this.nl(out);
            out.push('}');
        }
        this.depth -= 1;
        this.nl(out);
        out.push('}');
        return;
    }
    out.append("switch (");
    this.full(out, v);
    out.append(") {");
    for (c&) in cases.items() {
        this.nl(out);
        out.append("case ");
        this.int_lit(out, c.value, vt);
        out.push(':');
        this.nested(out, c.body);
        this.depth += 1;
        this.nl(out);
        out.append("break;");
        this.depth -= 1;
    }
    if (d) {
        this.nl(out);
        out.append("default:");
        this.nested(out, d);
        this.depth += 1;
        this.nl(out);
        out.append("break;");
        this.depth -= 1;
    }
    this.nl(out);
    out.push('}');
}

// ---------- functions ----------

// fn i's C prototype (named: with parameter names, for the definition); an exported main gets C's
// int main(argc, argv) and a real_name binds the symbol with VOLT_SYM
attach fn fn_header(this: cgen&, out: std::string&, i: u32, named: bool) -> void {
    val f = this.c.ir.fn_at(i);
    if (f.name == "main" && f.link == linkage::EXPORTED) {
        out.append("int main(int ");
        if (named) {
            out.append(*this.locals.at(0));
            out.append(", char **");
            out.append(*this.locals.at(1));
        } else {
            out.append("argc, char **argv");
        }
        out.push(')');
        return;
    }
    val a = f.attrs;
    if (a.is_inline) {
        out.append("__attribute__((always_inline)) inline ");
    }
    if (a.noinline) {
        out.append("__attribute__((noinline)) ");
    }
    if (a.opt) {
        out.append("__attribute__((optimize(\"O");
        out.append(a.opt);
        out.append("\"))) ");
    }
    if (a.section) {
        out.append("__attribute__((section(");
        put_c_str(out, a.section);
        out.append("))) ");
    }
    if (a.align) {
        out.append("__attribute__((aligned(");
        out.append(a.align);
        out.append("))) ");
    }
    if (a.deprecated) {
        out.append("__attribute__((deprecated)) ");
    }
    if (f.link == linkage::STATIC) {
        out.append("static ");
    }
    if (f.ret == NEVER) {
        out.append("_Noreturn void");
    } else {
        out.append(this.ty(f.ret));
    }
    out.push(' ');
    out.append(f.name);
    out.push('(');
    var first = true;
    for (p&) in f.params.items() {
        val l = f.locals.at(@cast<usize>(*p));
        if (l.ty == VOID) {
            continue;
        }
        if (!first) {
            out.append(", ");
        }
        first = false;
        out.append(this.ty(l.ty));
        if (named) {
            out.push(' ');
            out.append(*this.locals.at(@cast<usize>(*p)));
        }
    }
    if (f.c_varargs) {
        out.append(", ...");
    } else if (first) {
        out.append("void");
    }
    out.push(')');
    // the symbol goes on the prototype: C allows no asm label on a definition
    val real = f.real_name;
    if (real) {
        if (!named) {
            out.append(" VOLT_SYM(\"");
            out.append(real);
            out.append("\")");
        }
    }
}

fn is_c_keyword(n: str) -> bool {
    return c_member(n).len == 0;
}

// a name a local can't have in the C: a keyword, a type or macro name, or one of the names
// generated code uses (v_*, vp_*, vg_*, vpg_*, volt*)
fn c_reserved(s: str) -> bool {
    if (is_c_keyword(s) || starts_with(s, "volt") || starts_with(s, "v_") || starts_with(s, "vp") || starts_with(s, "vg")) {
        return true;
    }
    if (ends_with(s, "_t") || s == "bool" || s == "true" || s == "false" || s == "NULL" || s == "main") {
        return true;
    }
    // headers name their macros in capitals (EOF, SIZE_MAX); these few are lowercase, and gnu11
    // predefines linux, unix and i386
    val macros: str[28] = {
        "errno", "stdin", "stdout", "stderr", "environ", "linux", "unix", "i386", "complex", "imaginary",
        "alignas", "alignof", "noreturn", "static_assert", "thread_local", "and", "or", "not", "xor",
        "bitand", "bitor", "compl", "and_eq", "or_eq", "xor_eq", "not_eq", "va_list", "jmp_buf",
    };
    for (m) in macros {
        if (s == m) {
            return true;
        }
    }
    var lower = false;
    for (c) in s {
        lower = lower || (c >= 'a' && c <= 'z');
    }
    // _X and __x are the C implementation's
    return !lower || (s.len > 1 && s[0] == '_' && ((s[1] >= 'A' && s[1] <= 'Z') || s[1] == '_'));
}

// every file-scope C name the program declares (fns, externs, globals, types): a local with one
// of these names would hide it from the code after the local's declaration
attach fn global_names(this: cgen&) -> void {
    if (this.globals.len > 0) {
        return;
    }
    this.globals.put("", true);
    for (f&) in this.c.ir.fns.items() {
        this.globals.put(f.name, true);
        val r = f.real_name;
        if (r) {
            this.globals.put(r, true);
        }
    }
    for (g&) in this.c.ir.globals.items() {
        this.globals.put(g.name, true);
    }
    for (s&) in this.c.structs.items() {
        this.globals.put(s.c_name, true);
    }
    for (e&) in this.c.enums.items() {
        this.globals.put(e.c_name, true);
    }
}

// C names for the fn's locals: the Volt name, with _N added when it's taken or reserved
attach fn name_locals(this: cgen&, i: u32) -> void {
    this.locals = {};
    this.global_names();
    var seen: std::map<str, bool> = {};
    val ls = &this.c.ir.fn_at(i).locals;
    for (k) in 0..ls.len {
        val base = ls.at(k).name;
        var name = base;
        // renamed, it only has to be free (a user's own x_3 may hold the name x gets: add _k again)
        var bad = base.len == 0 || c_reserved(base);
        while (bad || seen.get(name) != null || this.globals.get(name) != null) {
            bad = false;
            var n = S(name);
            n.push('_');
            n.append_uint(@cast<u64>(k));
            name = this.c.intern(move n);
        }
        seen.put(name, true);
        put(&this.locals, name);
    }
}

// fn i's C definition: every local except params declared up front, then the body
attach fn fn_body(this: cgen&, out: std::string&, i: u32) -> void {
    this.fn_idx = i;
    this.tmp = 0;
    this.at_line = 0;
    this.name_locals(i);
    this.fn_header(out, i, true);
    out.append(" {");
    val f = this.c.ir.fn_at(i);
    var is_param: std::map<u32, bool> = {};
    for (p&) in f.params.items() {
        is_param.put(*p, true);
    }
    this.depth = 1;
    this.inline = 0;
    // which locals the body uses and which labels it jumps to: only those are printed
    var used: std::map<u32, bool> = {};
    this.targets = {};
    if (f.body) {
        var todo = nodes(f.body);
        var seen: std::map<u32, bool> = {}; // subtrees can be shared
        while (todo.len > 0) {
            val n = todo.pop() ?? 0;
            if (seen.get(n) != null) {
                continue;
            }
            seen.put(n, true);
            match (this.c.ir.at(n).kind) {
                .LOCAL(id) => { used.put(id, true); },
                .DECL(id, init) => { used.put(id, true); },
                .GOTO(l) => { this.targets.put(l, true); },
                default => {},
            }
            this.c.ir.kids(n, &todo);
        }
    }
    var declared = false;
    for (k) in 0..f.locals.len {
        val l = f.locals.at(k);
        if (is_param.get(@cast<u32>(k)) != null || l.ty == VOID || l.ty == NEVER || used.get(@cast<u32>(k)) == null) {
            continue;
        }
        out.append("\n    ");
        out.append(this.ty(l.ty));
        out.push(' ');
        out.append(*this.locals.at(k));
        out.push(';');
        declared = true;
    }
    if (declared) {
        out.push('\n'); // a blank line between the locals and the code
    }
    if (f.body) {
        this.stmt(out, f.body);
    }
    this.depth = 0;
    out.append("\n}\n\n");
}

// ---------- the unit ----------

// global g's C declaration, with its initializer when it is defined here
// a global's declaration for volt.h: extern, or a static one's tentative definition
attach fn global_decl(this: cgen&, out: std::string&, g: u32) -> void {
    val gl = this.c.ir.globals.at(@cast<usize>(g));
    if (gl.link == linkage::STATIC) {
        out.append("static ");
    } else {
        out.append("extern ");
    }
    if (gl.tls) {
        out.append("_Thread_local ");
    }
    out.append(this.ty(gl.ty));
    out.push(' ');
    out.append(gl.name);
    out.append(";\n");
}

attach fn global_def(this: cgen&, out: std::string&, g: u32) -> void {
    val gl = this.c.ir.globals.at(@cast<usize>(g));
    if (gl.header) {
        return; // an included header (or the runtime prelude) declares it
    }
    if (gl.link == linkage::EXTERNAL) {
        out.append("extern ");
    } else if (gl.link == linkage::STATIC) {
        out.append("static ");
    }
    if (gl.keep) {
        out.append("__attribute__((used)) ");
    }
    if (gl.tls) {
        out.append("_Thread_local ");
    }
    out.append(this.ty(gl.ty));
    out.push(' ');
    out.append(gl.name);
    if (gl.init != null && gl.link != linkage::EXTERNAL) {
        out.append(" = ");
        // an initializer belongs to no fn: clear the per-fn state
        this.fn_idx = 0;
        this.locals = {};
        this.value_as(out, gl.init ?? 0, gl.ty);
    }
    out.append(";\n");
}

// the program as one C unit
// one generated C file
struct c_file {
    name: std::string;
    text: std::string;
}

// the C for the whole program as files: volt.h (prelude, types, prototypes, global declarations),
// runtime.c, one .c per Volt source file holding its functions and globals, glue.c (generated
// helpers: drop and copy glue, error names), and program.c, which includes them all: the program
// builds as that one unit, so nothing about linkage changes
attach fn c_files(this: checker&) -> std::vec<c_file> {
    var g: cgen = { c: this };
    val live = reachable(this);
    // which output file each source file goes to (glue for no source)
    val glue_file = this.files.len;
    var parts: std::vec<std::string> = {};
    for (i) in 0..this.files.len + 1 {
        put(&parts, {});
    }
    // bodies first: writing them names the types that the type definitions below must cover
    for (b&) in this.ir.bodies.items() {
        val f = this.ir.fn_at(*b);
        if (f.body == null || !f.used || f.link == linkage::EXTERNAL || live.get(*b) == null) {
            continue;
        }
        var at = glue_file;
        val o = f.origin;
        if (o) {
            at = @cast<usize>(o.file);
            // the Volt it comes from, above the function
            val part = parts.at(at);
            part.append("// ");
            if (f.about.len > 0) {
                part.append(f.about);
                part.append(" (");
            }
            part.append(this.files.at(@cast<usize>(o.file)).name);
            part.push(':');
            part.append_uint(@cast<u64>(this.line_col(o).line));
            if (f.about.len > 0) {
                part.push(')');
            }
            part.push('\n');
            if (this.opts.line_info) {
                line_directive(part, this.files.at(@cast<usize>(o.file)).name, @cast<u32>(this.line_col(o).line));
                part.push('\n');
            }
        }
        g.fn_body(parts.at(at), *b);
        if (this.opts.line_info) {
            // what comes next (drop glue, another fn's prologue) isn't from that Volt line
            line_directive(parts.at(at), "<generated>", 1);
            parts.at(at).push('\n');
        }
    }
    // prototypes in first-use order; none for main, nor for prelude and header fns (declared already)
    var protos: std::string = {};
    var declared: std::map<u32, bool> = {};
    for (o&) in this.ir.order.items() {
        val f = this.ir.fn_at(*o);
        if (declared.get(*o) != null || !f.used || f.prelude || f.from_header || (f.name == "main" && f.link == linkage::EXPORTED)) {
            continue;
        }
        if (live.get(*o) == null) {
            continue; // never called: left out
        }
        declared.put(*o, true);
        g.locals = {};
        g.fn_header(&protos, *o, false);
        protos.append(";\n");
    }
    // globals: declared in volt.h (any unit's code may use them), defined with their source
    var global_decls: std::string = {};
    for (i) in 0..this.ir.globals.len {
        val gl = this.ir.globals.at(i);
        if (gl.header) {
            continue;
        }
        g.global_decl(&global_decls, @cast<u32>(i));
        if (gl.link == linkage::EXTERNAL) {
            continue;
        }
        var at = glue_file;
        val o = gl.origin;
        if (o) {
            at = @cast<usize>(o.file);
        }
        g.global_def(parts.at(at), @cast<u32>(i));
    }
    // every type is named by now, so its definitions can go out
    g.type_defs();
    var files: std::vec<c_file> = {};
    var h = S("// volt.h: what every part of the program needs: the runtime prelude, C headers, the types,\n// and the declarations of every function and global\n");
    if (!this.opts.release) {
        h.append("#define VOLT_DEBUG_ALLOC 1\n");
    }
    h.append(PRELUDE_H);
    h.push('\n');
    for (inc&) in this.c_includes.items() {
        h.append(*inc);
        h.push('\n');
    }
    h.append("\n// ---------- types ----------\n\n");
    h.append(g.fwd.as_str());
    h.append(g.defs.as_str());
    h.append("\n// ---------- functions ----------\n\n");
    h.append(protos.as_str());
    if (global_decls.len() > 0) {
        h.append("\n// ---------- globals ----------\n\n");
        h.append(global_decls.as_str());
    }
    put(&files, { name: S("volt.h"), text: move h });
    if (this.opts.runtime) {
        var rt = S("// runtime.c: the runtime (allocator, arguments), defined once in each program\n");
        rt.append(RUNTIME_H);
        put(&files, { name: S("runtime.c"), text: move rt });
    }
    // a file per Volt source with code in it, named after it (a package's prefixed with the package)
    var taken: std::map<str, bool> = {};
    for (i) in 0..parts.len {
        if (parts.at(i).len() == 0) {
            continue;
        }
        var name: std::string = {};
        var head: std::string = {};
        if (i == glue_file) {
            name = S("glue.c");
            head = S("// glue.c: helpers the compiler generates (deleting and copying values, error names)\n\n");
        } else {
            val src = this.files.at(i).name;
            name = S(c_file_stem(src));
            for (p&) in this.opts.pkg_files.items() {
                if (p.file == @cast<u32>(i)) {
                    var pn = S(p.pkg);
                    pn.push('_');
                    pn.append(name.as_str());
                    name = move pn;
                }
            }
            val base = copy name;
            var n: u32 = 2;
            while (taken.get(name.as_str()) != null) {
                name = copy base;
                name.push('_');
                name.append_uint(@cast<u64>(n));
                n += 1;
            }
            name.append(".c");
            head = S("// ");
            head.append(name.as_str());
            head.append(": the code from ");
            head.append(src);
            head.append("\n\n");
        }
        taken.put(this.intern(copy name), true);
        head.append(parts.at(i).as_str());
        put(&files, { name: move name, text: move head });
    }
    // the unit that includes them all
    var prog = S("// program.c: the whole program as one C unit: cc program.c builds it\n#include \"volt.h\"\n");
    for (k) in 1..files.len {
        prog.append("#include \"");
        prog.append(files.at(k).name.as_str());
        prog.append("\"\n");
    }
    put(&files, { name: S("program.c"), text: move prog });
    return move files;
}

// the fns the C needs: everything reachable from what's visible outside (main, exported fns),
// from global initializers and from fns placed in a section; a program leaves out the unused
// fns every package has (each one is still checked)
fn reachable(c: checker&) -> std::map<u32, bool> {
    var live: std::map<u32, bool> = {};
    var todo: std::vec<u32> = {};
    for (i) in 0..c.ir.fns.len {
        val f = c.ir.fn_at(@cast<u32>(i));
        if (f.body != null && (f.link == linkage::EXPORTED || f.attrs.section != null)) {
            put(&todo, @cast<u32>(i));
        }
    }
    var nodes_todo: std::vec<u32> = {};
    for (gl&) in c.ir.globals.items() {
        if (gl.init) {
            put(&nodes_todo, gl.init);
        }
    }
    var seen: std::map<u32, bool> = {};
    loop {
        // a fn's body, then the nodes it holds
        while (todo.len > 0) {
            val i = todo.pop() ?? 0;
            if (live.get(i) != null) {
                continue;
            }
            live.put(i, true);
            val f = c.ir.fn_at(i);
            if (f.body) {
                put(&nodes_todo, f.body);
            }
            val a = f.async_of;
            if (a) {
                put(&todo, a);
            }
        }
        if (nodes_todo.len == 0) {
            break;
        }
        while (nodes_todo.len > 0) {
            val n = nodes_todo.pop() ?? 0;
            if (seen.get(n) != null) {
                continue;
            }
            seen.put(n, true);
            match (c.ir.at(n).kind) {
                .FN(i) => { put(&todo, i); },
                default => {},
            }
            c.ir.kids(n, &nodes_todo);
        }
    }
    return move live;
}

// a source path's file name without directories or .volt, kept to what a file name may hold
fn c_file_stem(path: str) -> str {
    var start: usize = 0;
    for (i) in 0..path.len {
        if (path[i] == '/') {
            start = i + 1;
        }
    }
    var end = path.len;
    if (ends_with(path, ".volt")) {
        end -= 5;
    }
    if (end <= start) {
        return "unit";
    }
    return path[start..end];
}

// the program as one C text: every file program.c includes, in its order
attach fn c_unit(this: checker&) -> std::string {
    val files = this.c_files();
    var out: std::string = {};
    for (k) in 0..files.len - 1 {
        out.append(files.at(k).text.as_str());
        out.push('\n');
    }
    return move out;
}
