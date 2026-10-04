// C header import: a port of bootstrap/cimport.rs. `use { "stdio.h" } as c;` runs the C preprocessor over
// the headers and reads back what maps to Volt: functions (static inline ones too), structs, enum
// constants, numeric #defines and extern variables, as ordinary items of namespace `c`. The headers
// are #included in the generated C, so calls go through C's own prototypes and structs keep C's
// layout. A union is a struct whose fields share offset 0; a bitfield gets two static inline C
// functions, S_get_F and S_set_F, next to the #include (C does the bit work on both backends). The
// parser is tolerant: a declaration it can't read or map (long double, va_list...) is skipped, not
// an error. C pointers can be null: raw T*, a char* is a cstr?, a function pointer an optional fn.
use std::mem;

// the extern_abi of fns declared by an imported header (C's own prototype is used)
val C_HEADER: str = "C header";

// a C token; a string literal keeps no text (it only needs skipping)
enum ctok {
    ID: str,
    NUM: str,
    STR,
    CHR: u32,
    P: str,
}

// C punctuators, longest first so the first match is the whole one
fn c_puncts() -> std::vec<str> {
    var v: std::vec<str> = {};
    val all: str[34] = { "...", "<<", ">>", "->", "&&", "||", "==", "!=", "<=", ">=", "++", "--", "*", "(", ")", "[", "]", "{", "}", ",", ";", "=", ":", "?", "<", ">", "+", "-", "~", "!", "&", "|", "^", "/" };
    for (p) in all {
        put(&v, p);
    }
    return v;
}

fn c_is_alnum(c: u8) -> bool {
    return is_alpha(c) || is_digit(c);
}

// does s have p at byte i?
fn starts_at(s: str, i: usize, p: str) -> bool {
    if (i + p.len > s.len) {
        return false;
    }
    for (k) in 0..p.len {
        if (s[i + k] != p[k]) {
            return false;
        }
    }
    return true;
}

// tokens of preprocessed C; `#` lines are skipped, and any character that isn't a punctuator
// (`%`, `.`, ...) becomes `%`, the only one of them the evaluator uses
fn c_lex(src: str) -> std::vec<ctok> {
    val puncts = c_puncts();
    var out: std::vec<ctok> = {};
    var i: usize = 0;
    while (i < src.len) {
        val c = src[i];
        if (c == ' ' || c == '\t' || c == '\n' || c == '\r' || c == 11 || c == 12) {
            i += 1;
        } else if (c == '#') {
            while (i < src.len && src[i] != '\n') {
                i += 1;
            }
        } else if (is_alpha(c) || c == '_') {
            val s = i;
            while (i < src.len && (c_is_alnum(src[i]) || src[i] == '_')) {
                i += 1;
            }
            put(&out, ctok::ID(src[s..i]));
        } else if (is_digit(c) || (c == '.' && i + 1 < src.len && is_digit(src[i + 1]))) {
            val s = i;
            while (i < src.len && (c_is_alnum(src[i]) || src[i] == '.' || src[i] == '_' || ((src[i] == '+' || src[i] == '-') && (src[i - 1] == 'e' || src[i - 1] == 'E' || src[i - 1] == 'p' || src[i - 1] == 'P')))) {
                i += 1;
            }
            put(&out, ctok::NUM(src[s..i]));
        } else if (c == '"' || c == '\'') {
            val s = i + 1;
            i += 1;
            while (i < src.len && src[i] != c) {
                if (src[i] == '\\') {
                    i += 2;
                } else {
                    i += 1;
                }
            }
            var e = i;
            if (e > src.len) {
                e = src.len;
            }
            val body = src[s..e];
            i += 1;
            if (c == '"') {
                put(&out, ctok::STR);
            } else {
                put(&out, ctok::CHR(char_value(body)));
            }
        } else {
            var found: str? = null;
            for (p&) in puncts.items() {
                if (found == null && starts_at(src, i, *p)) {
                    found = *p;
                }
            }
            if (found) {
                put(&out, ctok::P(found));
                i += found.len;
            } else {
                put(&out, ctok::P("%"));
                i += 1;
            }
        }
    }
    return out;
}

fn digit_val(c: u8) -> u32? {
    if (c >= '0' && c <= '9') {
        return @cast<u32>(c - '0');
    }
    if (c >= 'a' && c <= 'f') {
        return @cast<u32>(c - 'a') + 10;
    }
    if (c >= 'A' && c <= 'F') {
        return @cast<u32>(c - 'A') + 10;
    }
    return null;
}

// digits in a radix, like Rust's from_str_radix: all must be valid, no overflow
fn parse_radix(s: str, radix: u32) -> i128? {
    if (s.len == 0) {
        return null;
    }
    var v: i128 = 0;
    var start: usize = 0;
    var neg = false;
    if (s[0] == '+' || s[0] == '-') {
        neg = s[0] == '-';
        start = 1;
        if (s.len == 1) {
            return null;
        }
    }
    for (i) in start..s.len {
        val d = digit_val(s[i]) ?? return null;
        if (d >= radix) {
            return null;
        }
        v = mul_i128(v, @cast<i128>(radix)) ?? return null;
        if (neg) {
            v = sub_i128(v, @cast<i128>(d)) ?? return null;
        } else {
            v = add_i128(v, @cast<i128>(d)) ?? return null;
        }
    }
    return v;
}

// the value of a character literal's body (the text between the quotes)
fn char_value(body: str) -> u32 {
    if (body.len == 0) {
        return 0;
    }
    if (body[0] != '\\' || body.len < 2) {
        return @cast<u32>(body.ptr[0]);
    }
    val c = body[1];
    if (c == 'n') {
        if (body.len == 2) {
            return 10;
        }
    } else if (c == 't') {
        if (body.len == 2) {
            return 9;
        }
    } else if (c == 'r') {
        if (body.len == 2) {
            return 13;
        }
    }
    if (c >= '0' && c <= '7') {
        return @cast<u32>(parse_radix(body[1..body.len], 8) ?? 0);
    }
    if (c == 'x') {
        return @cast<u32>(parse_radix(body[2..body.len], 16) ?? 0);
    }
    if (body.len == 2) {
        return @cast<u32>(c);
    }
    return @cast<u32>(body.ptr[0]);
}

// ---------- constant expressions (enum values, #defines, array lengths) ----------

// a C constant: an int with its unsigned/long suffixes, or a float
struct cnum {
    is_float: bool = false;
    v: i128 = 0;
    unsigned: bool = false;
    long: bool = false;
    f: f64 = 0.0;
}

fn cint(v: i128, u: bool, l: bool) -> cnum {
    return { v: v, unsigned: u, long: l };
}

fn cfloat(f: f64) -> cnum {
    return { is_float: true, f: f };
}


// a C number literal: an int with its u/l suffixes, or a float; none if it isn't one
fn parse_cnum(s: str) -> cnum? {
    var l: std::string = {};
    for (c) in s {
        if (c >= 'A' && c <= 'Z') {
            l.push(c + 32);
        } else {
            l.push(c);
        }
    }
    val t = l.as_str();
    val hex = t.len >= 2 && t[0] == '0' && t[1] == 'x';
    var has_dot = false;
    var has_e = false;
    var has_p = false;
    for (c) in t {
        if (c == '.') {
            has_dot = true;
        } else if (c == 'e') {
            has_e = true;
        } else if (c == 'p') {
            has_p = true;
        }
    }
    if (has_dot || (!hex && has_e) || (hex && has_p)) {
        var end = t.len;
        while (end > 0 && (t[end - 1] == 'f' || t[end - 1] == 'l')) {
            end -= 1;
        }
        // Rust's f64 parse: the whole text must be a number (strtod reads hex floats too)
        var num = S(t[0..end]);
        var stop: u8* = null;
        val f = strtod(num.c_str(), @cast<void*>(&stop));
        val used = @cast<usize>(stop) - @cast<usize>(num.as_str().ptr);
        if (end == 0 || used != end || hex) {
            return null;
        }
        return cfloat(f);
    }
    var dend = t.len;
    while (dend > 0 && (t[dend - 1] == 'u' || t[dend - 1] == 'l')) {
        dend -= 1;
    }
    val digits = t[0..dend];
    val suffix = t[dend..t.len];
    val unsigned = contains(suffix, "u");
    val long = contains(suffix, "l");
    var v: i128 = 0;
    if (hex) {
        v = parse_radix(digits[2..digits.len], 16) ?? return null;
    } else if (digits.len >= 2 && digits[0] == '0' && digits[1] == 'b') {
        v = parse_radix(digits[2..digits.len], 2) ?? return null;
    } else if (digits.len > 1 && digits[0] == '0') {
        v = parse_radix(digits[1..digits.len], 8) ?? return null;
    } else {
        v = parse_radix(digits, 10) ?? return null;
    }
    return cint(v, unsigned, long);
}

// precedence climbing over a constant expression's tokens; env holds the constants known so far
struct ceval {
    t: ctok[..];
    i: usize;
    env: std::map<str, cnum>&;
}

// a binary operator's precedence (higher binds tighter); none if it isn't one
fn prec_of(op: str) -> u32? {
    if (op == "||") { return 1; }
    if (op == "&&") { return 2; }
    if (op == "|") { return 3; }
    if (op == "^") { return 4; }
    if (op == "&") { return 5; }
    if (op == "==" || op == "!=") { return 6; }
    if (op == "<" || op == ">" || op == "<=" || op == ">=") { return 7; }
    if (op == "<<" || op == ">>") { return 8; }
    if (op == "+" || op == "-") { return 9; }
    if (op == "*" || op == "/" || op == "%") { return 10; }
    return null;
}

// is t the punctuator p?
fn is_p(t: ctok*, p: str) -> bool {
    val x = t ?? return false;
    match (*x) {
        .P(q) => { return q == p; },
        default => { return false; },
    }
}

attach fn peek(this: ceval&) -> ctok* {
    if (this.i < this.t.len) {
        return &this.t[this.i];
    }
    return null;
}

// an expression whose operators bind at least as tight as `min`
attach fn expr(this: ceval&, min: u32) -> cnum? {
    var lhs = this.unary() ?? return null;
    loop {
        val t = this.peek() ?? break;
        var op: str = "";
        match (*t) {
            .P(q) => { op = q; },
            default => { break; },
        }
        val p = prec_of(op) ?? break;
        if (p < min) {
            break;
        }
        this.i += 1;
        val rhs = this.expr(p + 1) ?? return null;
        lhs = cbinop(op, lhs, rhs) ?? return null;
    }
    return lhs;
}

// type names that can start a cast in a constant expression
fn is_type_word(n: str) -> bool {
    val words: str[13] = { "int", "unsigned", "signed", "long", "short", "char", "float", "double", "size_t", "int32_t", "uint32_t", "int64_t", "uint64_t" };
    for (w) in words {
        if (w == n) {
            return true;
        }
    }
    return false;
}

attach fn unary(this: ceval&) -> cnum? {
    val t = this.peek() ?? return null;
    this.i += 1;
    match (*t) {
        .NUM(s) => { return parse_cnum(s); },
        .CHR(c) => { return cint(@cast<i128>(c), false, false); },
        .ID(n) => {
            val v = this.env.get(n) ?? return null;
            return *v;
        },
        .P(p) => {
            if (p == "-") {
                val x = this.unary() ?? return null;
                if (x.is_float) {
                    return cfloat(-x.f);
                }
                return cint(-x.v, x.unsigned, x.long);
            }
            if (p == "+") {
                return this.unary();
            }
            if (p == "~") {
                val x = this.unary() ?? return null;
                if (x.is_float) {
                    return null;
                }
                return cint(~x.v, x.unsigned, x.long);
            }
            if (p == "!") {
                val x = this.unary() ?? return null;
                if (x.is_float) {
                    return null;
                }
                if (x.v == 0) {
                    return cint(1, false, false);
                }
                return cint(0, false, false);
            }
            if (p == "(") {
                // a cast like (int) or (unsigned long): skip it
                var cast = false;
                val nt = this.peek();
                if (nt) {
                    match (*nt) {
                        .ID(n) => { cast = is_type_word(n); },
                        default => {},
                    }
                }
                if (cast) {
                    loop {
                        val q = this.peek() ?? break;
                        var id = false;
                        match (*q) {
                            .ID(n) => { id = true; },
                            default => {},
                        }
                        if (!id) {
                            break;
                        }
                        this.i += 1;
                    }
                    if (!is_p(this.peek(), ")")) {
                        return null;
                    }
                    this.i += 1;
                    return this.unary();
                }
                val v = this.expr(0) ?? return null;
                if (!is_p(this.peek(), ")")) {
                    return null;
                }
                this.i += 1;
                return v;
            }
            return null;
        },
        default => { return null; },
    }
}

fn b2i(b: bool) -> i128 {
    if (b) {
        return 1;
    }
    return 0;
}

// a C operator on two constants: ints in i128 (none on overflow or division by zero), unsigned or long
// if either side is; anything with a float as f64 (+ - * / only)
fn cbinop(op: str, a: cnum, b: cnum) -> cnum? {
    if (!a.is_float && !b.is_float) {
        val x = a.v;
        val y = b.v;
        val u = a.unsigned || b.unsigned;
        val l = a.long || b.long;
        var v: i128 = 0;
        if (op == "+") { v = add_i128(x, y) ?? return null; }
        else if (op == "-") { v = sub_i128(x, y) ?? return null; }
        else if (op == "*") { v = mul_i128(x, y) ?? return null; }
        else if (op == "/") { v = div_i128(x, y) ?? return null; }
        else if (op == "%") { v = rem_i128(x, y) ?? return null; }
        else if (op == "<<") {
            if (y < 0 || y > 4294967295) {
                return null;
            }
            v = shl_i128(x, y) ?? return null;
        } else if (op == ">>") {
            if (y < 0 || y > 4294967295) {
                return null;
            }
            v = shr_i128(x, y) ?? return null;
        }
        else if (op == "&") { v = x & y; }
        else if (op == "|") { v = x | y; }
        else if (op == "^") { v = x ^ y; }
        else if (op == "&&") { v = b2i(x != 0 && y != 0); }
        else if (op == "||") { v = b2i(x != 0 || y != 0); }
        else if (op == "==") { v = b2i(x == y); }
        else if (op == "!=") { v = b2i(x != y); }
        else if (op == "<") { v = b2i(x < y); }
        else if (op == ">") { v = b2i(x > y); }
        else if (op == "<=") { v = b2i(x <= y); }
        else if (op == ">=") { v = b2i(x >= y); }
        else { return null; }
        return cint(v, u, l);
    }
    var x = a.f;
    if (!a.is_float) {
        x = @cast<f64>(a.v);
    }
    var y = b.f;
    if (!b.is_float) {
        y = @cast<f64>(b.v);
    }
    if (op == "+") { return cfloat(x + y); }
    if (op == "-") { return cfloat(x - y); }
    if (op == "*") { return cfloat(x * y); }
    if (op == "/") { return cfloat(x / y); }
    return null;
}

// value of a C constant expression (numbers, enum constants, operators); none if it isn't one
fn const_eval(t: ctok[..], env: std::map<str, cnum>&) -> cnum? {
    var e: ceval = { t: t, i: 0, env: env };
    val v = e.expr(0) ?? return null;
    if (e.i != t.len) {
        return null;
    }
    return v;
}

// ---------- declarations ----------

// a C type as the declaration parser reads it
enum ctype {
    VOID,
    BOOL,
    CHAR,
    PRIM: str,    // a Volt primitive name
    NAMED: str,   // a typedef name
    STRUCT: str,  // by tag (anonymous ones get a made-up tag)
    PTR: std::box<ctype>,
    ARRAY: (std::box<ctype>, u64?),
    FUNC: (std::vec<ctype>, std::box<ctype>, bool),
    BAD,          // long double, va_list...: can't be used by value
}

struct cfield_decl {
    name: str;
    ty: ctype;
    // a bitfield (a nameless placeholder for the layout): its name and its type's C text, for its
    // accessors
    bit_name: str = "";
    bits: str? = null;
}

struct cstruct {
    tag: str;
    fields: std::vec<cfield_decl>?; // none: only declared
    is_union: bool = false;
}

// an anonymous struct or union that is the type of a named field: where it is
struct anon_field {
    outer: str; // the enclosing struct's tag
    field: str;
}

struct cparam {
    name: str?;
    ty: ctype;
}

struct cfn {
    name: str;
    params: std::vec<cparam>;
    ret: ctype;
    variadic: bool;
}

struct cvar {
    name: str;
    ty: ctype;
}

struct cconst {
    name: str;
    v: cnum;
}

// everything read from the preprocessed headers
struct cdecls {
    typedefs: std::map<str, ctype> = {};
    structs: std::vec<cstruct> = {};
    typedef_of: std::map<str, str> = {}; // struct tag -> first typedef naming it
    typedef_order: std::vec<str> = {};   // typedef names in the order they're declared
    // consts: enum constants and numeric #defines, in order; env: every constant by name, for
    // evaluating later ones
    consts: std::vec<cconst> = {};
    env: std::map<str, cnum> = {};
    fns: std::vec<cfn> = {};
    vars: std::vec<cvar> = {};
    // counter for made-up tags of anonymous structs
    anon: u32 = 0;
    last_params: std::vec<str?> = {}; // names in the param list read last (the declared fn's own)
    names: std::vec<std::string> = {}; // made-up names (anonymous tags) the others point into
    anon_in: std::map<str, anon_field> = {}; // anonymous tag -> the named field it types
}

// records a struct tag; a later definition fills in the fields of an earlier declaration
attach fn define_struct(this: cdecls&, tag: str, fields: std::vec<cfield_decl>?, is_union: bool) -> void {
    var at: usize? = null;
    for (i) in 0..this.structs.len {
        if (this.structs.at(i).tag == tag) {
            at = i;
        }
    }
    if (at) {
        if (fields != null) {
            this.structs.at(at).fields = move fields;
            this.structs.at(at).is_union = is_union;
        }
        return;
    }
    put(&this.structs, { tag: tag, fields: move fields, is_union: is_union });
}

// tokens as C text (a bitfield's type, for its accessors); none if one has no text kept
attach fn text_of(this: cdecls&, t: ctok[..]) -> str? {
    var out = S("");
    for (k&) in t {
        if (out.len() > 0) {
            out.push(' ');
        }
        match (*k) {
            .ID(n) => { out.append(n); },
            .NUM(n) => { out.append(n); },
            .P(p) => { out.append(p); },
            default => { return null; },
        }
    }
    put(&this.names, move out);
    return this.names.at(this.names.len - 1).as_str();
}

// a parser over one declaration's tokens, adding what it reads to `d`; a method that returns
// none or false found the declaration unreadable (it is skipped)
struct cparser {
    t: ctok[..];
    i: usize;
    d: cdecls&;
}

attach fn peek(this: cparser&) -> ctok* {
    if (this.i < this.t.len) {
        return &this.t[this.i];
    }
    return null;
}

attach fn peek_id(this: cparser&) -> str? {
    val t = this.peek() ?? return null;
    match (*t) {
        .ID(n) => { return n; },
        default => { return null; },
    }
}

attach fn is(this: cparser&, p: str) -> bool {
    return is_p(this.peek(), p);
}

attach fn eat(this: cparser&, p: str) -> bool {
    if (this.is(p)) {
        this.i += 1;
        return true;
    }
    return false;
}

// skip a balanced (...) / [...] / {...} starting at the current token; false if it doesn't close
attach fn skip_group(this: cparser&) -> bool {
    var depth: i32 = 0;
    loop {
        val t = this.peek() ?? return false;
        match (*t) {
            .P(p) => {
                if (p == "(" || p == "[" || p == "{") {
                    depth += 1;
                } else if (p == ")" || p == "]" || p == "}") {
                    depth -= 1;
                }
            },
            default => {},
        }
        this.i += 1;
        if (depth == 0) {
            return true;
        }
    }
    return false;
}

// qualifiers and storage words that don't change the type Volt sees
fn is_noise_word(n: str) -> bool {
    val words: str[22] = { "const", "__const", "volatile", "__volatile__", "restrict", "__restrict", "__restrict__", "inline", "__inline", "__inline__", "extern", "register", "_Noreturn", "__extension__", "auto", "_Nonnull", "_Nullable", "_Null_unspecified", "", "", "", "" };
    for (w) in words {
        if (w.len > 0 && w == n) {
            return true;
        }
    }
    return false;
}

// __attribute__((...)), __asm__("..."), and other noise that carries no type information.
// none: a group didn't close (the declaration is unreadable)
attach fn skip_noise(this: cparser&) -> bool? {
    val n = this.peek_id() ?? return false;
    if (n == "__attribute__" || n == "__attribute" || n == "__asm__" || n == "__asm" || n == "asm" || n == "__declspec" || n == "_Alignas" || n == "__typeof__") {
        this.i += 1;
        if (this.is("(") && !this.skip_group()) {
            return null;
        }
        return true;
    }
    if (is_noise_word(n)) {
        this.i += 1;
        return true;
    }
    return false;
}

// C typedef names with an exact Volt type (checked before following typedef chains)
fn known_typedef(n: str) -> str? {
    if (n == "size_t") { return "usize"; }
    if (n == "ssize_t") { return "isize"; }
    if (n == "ptrdiff_t") { return "isize"; }
    if (n == "intptr_t") { return "isize"; }
    if (n == "uintptr_t") { return "usize"; }
    if (n == "int8_t") { return "i8"; }
    if (n == "int16_t") { return "i16"; }
    if (n == "int32_t") { return "i32"; }
    if (n == "int64_t") { return "i64"; }
    if (n == "uint8_t") { return "u8"; }
    if (n == "uint16_t") { return "u16"; }
    if (n == "uint32_t") { return "u32"; }
    if (n == "uint64_t") { return "u64"; }
    if (n == "bool") { return "bool"; }
    return null;
}

// declaration specifiers -> base type; sets `stat` for static/thread-local storage
attach fn specs(this: cparser&, stat: bool&) -> ctype? {
    var signed = false;
    var unsigned = false;
    var short = false;
    var longs = 0;
    var int = false;
    var base: ctype? = null;
    loop {
        if (this.skip_noise() ?? return null) {
            continue;
        }
        val n = this.peek_id() ?? break;
        val seen = base != null || signed || unsigned || short || longs > 0 || int;
        if (n == "static" || n == "_Thread_local" || n == "__thread") {
            *stat = true;
        } else if (n == "signed" || n == "__signed__" || n == "__signed") {
            signed = true;
        } else if (n == "unsigned") {
            unsigned = true;
        } else if (n == "short") {
            short = true;
        } else if (n == "long") {
            longs += 1;
        } else if (n == "int") {
            int = true;
        } else if (n == "char") {
            base = ctype::CHAR;
        } else if (n == "void") {
            base = ctype::VOID;
        } else if (n == "_Bool" || n == "bool") {
            base = ctype::BOOL;
        } else if (n == "float" || n == "_Float32") {
            base = ctype::PRIM("f32");
        } else if (n == "double" || n == "_Float64") {
            base = ctype::PRIM("f64");
        } else if (n == "_Float128" || n == "__float128") {
            base = ctype::PRIM("f128");
        } else if (n == "__int128" || n == "__int128_t") {
            base = ctype::PRIM("i128");
        } else if (n == "__uint128_t") {
            base = ctype::PRIM("u128");
        } else if (n == "_Complex" || n == "__builtin_va_list" || n == "_Float32x" || n == "_Float64x" || n == "_Float128x" || n == "_Float16") {
            base = ctype::BAD;
        } else if (n == "struct" || n == "union") {
            this.i += 1;
            while (this.skip_noise() ?? return null) {}
            var tag: str = "";
            val t = this.peek_id();
            if (t) {
                tag = t;
                this.i += 1;
            } else {
                this.d.anon += 1;
                var a = S("#anon");
                a.append_uint(@cast<u64>(this.d.anon));
                put(&this.d.names, move a);
                tag = this.d.names.at(this.d.names.len - 1).as_str();
            }
            while (this.skip_noise() ?? return null) {}
            val is_union = n == "union";
            if (this.is("{")) {
                val fields = this.fields(tag);
                this.d.define_struct(tag, move fields, is_union);
            } else {
                this.d.define_struct(tag, null, is_union);
            }
            base = ctype::STRUCT(tag);
            continue;
        } else if (n == "enum") {
            this.i += 1;
            while (this.skip_noise() ?? return null) {}
            if (this.peek_id() != null) {
                this.i += 1;
            }
            if (this.is("{")) {
                if (!this.enumerators()) {
                    return null;
                }
            }
            base = ctype::PRIM("i32");
            continue;
        } else if (!seen && (this.d.typedefs.get(n) != null || known_typedef(n) != null)) {
            base = ctype::NAMED(n);
        } else {
            break;
        }
        this.i += 1;
    }
    if (base) {
        match (base) {
            .CHAR => {
                if (unsigned) {
                    return ctype::PRIM("u8");
                }
                if (signed) {
                    return ctype::PRIM("i8");
                }
            },
            .PRIM(p) => {
                if (p == "f64" && longs > 0) {
                    return ctype::BAD; // long double
                }
            },
            default => {},
        }
        return copy base;
    }
    if (!(signed || unsigned || short || longs > 0 || int)) {
        return null;
    }
    var bits = 32;
    if (short) {
        bits = 16;
    } else if (longs > 0) {
        bits = 64;
    }
    if (bits == 16) {
        if (unsigned) {
            return ctype::PRIM("u16");
        }
        return ctype::PRIM("i16");
    }
    if (bits == 32) {
        if (unsigned) {
            return ctype::PRIM("u32");
        }
        return ctype::PRIM("i32");
    }
    if (unsigned) {
        return ctype::PRIM("u64");
    }
    return ctype::PRIM("i64");
}

// `{ int a; char b[4]; ... }` of struct or union `tag`. A bitfield or a member Volt can't read
// becomes a nameless BAD placeholder, so c_items knows the layout is partial (a bitfield's
// placeholder keeps what its accessors need); an anonymous struct or union member's fields are the
// outer one's, as in C
attach fn fields(this: cparser&, tag: str) -> std::vec<cfield_decl>? {
    val open = this.i;
    if (!this.skip_group()) {
        return null;
    }
    val end = this.i - 1;
    var out: std::vec<cfield_decl> = {};
    var i = open + 1;
    while (i < end) {
        var stop = decl_end(this.t, i);
        if (stop > end) {
            stop = end;
        }
        var sub: cparser = { t: this.t[i..stop], i: 0, d: this.d };
        var stat = false;
        val b = sub.specs(&stat);
        val spec_end = sub.i;
        if (b) {
            loop {
                val got = sub.declarator(copy b);
                if (got == null) {
                    put(&out, { name: "", ty: ctype::BAD });
                    break;
                }
                val dc = got ?? break;
                val bitfield = sub.eat(":");
                if (bitfield) {
                    while (sub.peek() != null && !sub.is(",")) {
                        sub.i += 1;
                    }
                }
                var anon: str? = null;
                match (dc.ty) {
                    .STRUCT(t) => {
                        if (t.len > 0 && t[0] == '#') {
                            anon = t;
                        }
                    },
                    default => {},
                }
                if (bitfield) {
                    var f: cfield_decl = { name: "", ty: ctype::BAD };
                    if (dc.name != null) {
                        f.bit_name = dc.name ?? "";
                        f.bits = this.d.text_of(sub.t[0..spec_end]);
                    }
                    put(&out, move f);
                } else if (dc.name == null && anon != null) {
                    // C reaches its fields through the outer struct; only libclang knows where they are
                    for (s&) in this.d.structs.items() {
                        if (s.tag != (anon ?? "")) {
                            continue;
                        }
                        if (s.fields) {
                            for (f&) in s.fields.items() {
                                put(&out, { name: f.name, ty: copy f.ty, bit_name: f.bit_name, bits: f.bits });
                            }
                        }
                    }
                    put(&out, { name: "", ty: ctype::BAD });
                } else if (dc.name != null) {
                    if (anon) {
                        this.d.anon_in.put(anon, { outer: tag, field: dc.name ?? "" });
                    }
                    put(&out, { name: dc.name ?? "", ty: copy dc.ty });
                } else {
                    put(&out, { name: "", ty: ctype::BAD }); // dropped: the layout is partial
                }
                if (!sub.eat(",")) {
                    break;
                }
            }
        } else {
            // a type Volt can't read (__typeof__, _Atomic(T), ...): the layout is partial
            put(&out, { name: "", ty: ctype::BAD });
        }
        i = stop + 1;
    }
    return out;
}

// `{ A, B = 5, ... }`: each constant goes into consts and env
attach fn enumerators(this: cparser&) -> bool {
    if (!this.eat("{")) {
        return false;
    }
    var next = cint(0, false, false);
    while (!this.eat("}")) {
        val name = this.peek_id() ?? return false;
        this.i += 1;
        while (this.skip_noise() ?? return false) {}
        var value: cnum? = next;
        if (this.eat("=")) {
            val s = this.i;
            var depth = 0;
            loop {
                val t = this.peek() ?? break;
                var stop = false;
                match (*t) {
                    .P(p) => {
                        if (p == "(") {
                            depth += 1;
                        } else if (p == ")") {
                            depth -= 1;
                        } else if ((p == "," || p == "}") && depth == 0) {
                            stop = true;
                        }
                    },
                    default => {},
                }
                if (stop) {
                    break;
                }
                this.i += 1;
            }
            value = const_eval(this.t[s..this.i], &this.d.env);
        }
        if (value) {
            this.d.env.put(name, value);
            put(&this.d.consts, { name: name, v: value });
            next = cbinop("+", value, cint(1, false, false)) ?? return false;
        }
        this.eat(",");
    }
    return true;
}

// a declarator's name (none for an abstract one) and type
struct cdecl {
    name: str?;
    ty: ctype;
}

// pointers, a name or a (nested declarator), then [N] / (params) suffixes
attach fn declarator(this: cparser&, base: ctype) -> cdecl? {
    var ty = move base;
    loop {
        if (this.eat("*")) {
            ty = ctype::PTR(bx(move ty));
        } else if (!(this.skip_noise() ?? return null)) {
            break;
        }
    }
    // `(*name)(...)`: a nested declarator, which applies after the suffixes that follow it
    var nested = false;
    if (this.is("(") && this.i + 1 < this.t.len && !this.starts_params()) {
        match (this.t[this.i + 1]) {
            .P(p) => { nested = p == "*" || p == "("; },
            .ID(n) => { nested = true; },
            default => {},
        }
    }
    if (nested) {
        val open = this.i;
        if (!this.skip_group()) {
            return null;
        }
        val close = this.i;
        val outer = this.suffixes(move ty) ?? return null;
        val after = this.i;
        var inner: cparser = { t: this.t[open + 1..close - 1], i: 0, d: this.d };
        val r = inner.declarator(move outer) ?? return null;
        if (inner.peek() != null) {
            return null;
        }
        this.i = after;
        return r;
    }
    val name = this.peek_id();
    if (name != null) {
        this.i += 1;
    }
    while (this.skip_noise() ?? return null) {}
    val t = this.suffixes(move ty) ?? return null;
    return { name: name, ty: move t };
}

// words that start a parameter declaration (see starts_params)
fn is_param_word(n: str) -> bool {
    val words: str[23] = { "void", "char", "short", "int", "long", "float", "double", "signed", "unsigned", "_Bool", "struct", "union", "enum", "const", "volatile", "__const", "__extension__", "__attribute__", "__builtin_va_list", "__signed__", "__int128", "_Float128", "__restrict" };
    for (w) in words {
        if (w == n) {
            return true;
        }
    }
    return false;
}

// does the `(` here start a parameter list (rather than a nested declarator)?
attach fn starts_params(this: cparser&) -> bool {
    if (this.i + 1 >= this.t.len) {
        return false;
    }
    match (this.t[this.i + 1]) {
        .P(p) => { return p == ")" || p == "..."; },
        .ID(n) => { return this.d.typedefs.get(n) != null || known_typedef(n) != null || is_param_word(n); },
        default => { return false; },
    }
}

// array and parameter-list suffixes; `x[2][3]` is an array of 2 arrays of 3. An array length that
// isn't a constant makes the type BAD
attach fn suffixes(this: cparser&, ty: ctype) -> ctype? {
    if (this.is("[")) {
        val s = this.i + 1;
        if (!this.skip_group()) {
            return null;
        }
        val len_toks = this.t[s..this.i - 1];
        var len: u64? = null;
        if (len_toks.len > 0) {
            val n = const_eval(len_toks, &this.d.env) ?? return ctype::BAD;
            if (n.is_float || n.v < 0) {
                return ctype::BAD;
            }
            len = @cast<u64>(n.v);
        }
        val inner = this.suffixes(move ty) ?? return null;
        return ctype::ARRAY(bx(move inner), len);
    }
    if (this.is("(")) {
        var variadic = false;
        val params = this.params(&variadic) ?? return null;
        while (this.skip_noise() ?? return null) {}
        val ret = this.suffixes(move ty) ?? return null;
        var ps: std::vec<ctype> = {};
        for (p&) in params.items() {
            put(&ps, copy p.ty);
        }
        return ctype::FUNC(move ps, bx(move ret), variadic);
    }
    return ty;
}

// is this parameter list just `(void)`?
fn only_void(t: ctok[..]) -> bool {
    if (t.len != 1) {
        return false;
    }
    match (t[0]) {
        .ID(n) => { return n == "void"; },
        default => { return false; },
    }
}

// a parameter list: each param's name and type (variadic: it ends in `...`); the names are kept
// in last_params for the fn being declared
attach fn params(this: cparser&, variadic: bool&) -> std::vec<cparam>? {
    val open = this.i;
    if (!this.skip_group()) {
        return null;
    }
    val close = this.i - 1;
    val toks = this.t[open + 1..close];
    var out: std::vec<cparam> = {};
    if (toks.len == 0 || only_void(toks)) {
        return out;
    }
    for (part) in split_top(toks, ",").items() {
        if (part.len == 1 && is_p(&part[0], "...")) {
            *variadic = true;
            continue;
        }
        var sub: cparser = { t: part, i: 0, d: this.d };
        var stat = false;
        val base = sub.specs(&stat) ?? return null;
        val dc = sub.declarator(move base) ?? return null;
        if (sub.peek() != null) {
            return null;
        }
        // arrays and functions as params are pointers
        var ty = copy dc.ty;
        match (dc.ty) {
            .ARRAY(inner, n) => { ty = ctype::PTR(copy inner); },
            .FUNC(ps, r, v) => { ty = ctype::PTR(bx(copy dc.ty)); },
            default => {},
        }
        put(&out, { name: dc.name, ty: move ty });
    }
    this.d.last_params = {};
    for (p&) in out.items() {
        put(&this.d.last_params, p.name);
    }
    return out;
}

// one top-level declaration (the tokens up to its `;`, or up to a function body)
attach fn top(this: cparser&) -> void {
    if ((this.peek_id() ?? "") == "_Static_assert") {
        return;
    }
    val is_typedef = (this.peek_id() ?? "") == "typedef";
    if (is_typedef) {
        this.i += 1;
    }
    var stat = false;
    val base = this.specs(&stat) ?? return;
    loop {
        if (this.peek() == null || this.is(";")) {
            return;
        }
        val dc = this.declarator(copy base) ?? return;
        val name = dc.name ?? return;
        if (this.eat("=")) {
            return; // initialized variables in headers are static data, not imports
        }
        if (is_typedef) {
            match (dc.ty) {
                .STRUCT(tag) => {
                    // the struct's Volt name: its first public typedef (FILE, not __FILE)
                    val e = this.d.typedef_of.get(tag);
                    if (e == null) {
                        this.d.typedef_of.put(tag, name);
                    } else if (starts_with(*e, "__") && !starts_with(name, "__")) {
                        *e = name;
                    }
                },
                default => {},
            }
            if (this.d.typedefs.get(name) == null) {
                put(&this.d.typedef_order, name);
            }
            this.d.typedefs.put(name, copy dc.ty);
        } else if (!starts_with(name, "__")) {
            match (dc.ty) {
                .FUNC(ps, ret, variadic) => {
                    var names: std::vec<str?> = {};
                    swap(&names, &this.d.last_params);
                    var cps: std::vec<cparam> = {};
                    for (i) in 0..ps.len {
                        var pn: str? = null;
                        if (i < names.len) {
                            pn = *names.at(i);
                        }
                        put(&cps, { name: pn, ty: copy *ps.at(i) });
                    }
                    put(&this.d.fns, { name: name, params: move cps, ret: copy *ret.ptr, variadic: variadic });
                },
                default => {
                    if (!stat) {
                        put(&this.d.vars, { name: name, ty: copy dc.ty });
                    }
                },
            }
        }
        if (!this.eat(",")) {
            return;
        }
    }
}

// split tokens on top-level `sep`
fn split_top(t: ctok[..], sep: str) -> std::vec<ctok[..]> {
    var out: std::vec<ctok[..]> = {};
    var depth: i32 = 0;
    var s: usize = 0;
    for (i) in 0..t.len {
        match (t[i]) {
            .P(p) => {
                if (p == "(" || p == "[" || p == "{") {
                    depth += 1;
                } else if (p == ")" || p == "]" || p == "}") {
                    depth -= 1;
                } else if (depth == 0 && p == sep) {
                    put(&out, t[s..i]);
                    s = i + 1;
                }
            },
            default => {},
        }
    }
    put(&out, t[s..t.len]);
    return out;
}

// end of the declaration starting at i: its `;`, or the `{` of a function body
fn decl_end(t: ctok[..], start: usize) -> usize {
    var depth: i32 = 0;
    var i = start;
    while (i < t.len) {
        match (t[i]) {
            .P(p) => {
                if (p == "(" || p == "[") {
                    depth += 1;
                } else if (p == ")" || p == "]") {
                    depth -= 1;
                } else if (p == "{") {
                    if (depth == 0 && i > 0 && is_p(&t[i - 1], ")")) {
                        return i;
                    }
                    depth += 1;
                } else if (p == "}") {
                    depth -= 1;
                } else if (p == ";" && depth == 0) {
                    return i;
                }
            },
            default => {},
        }
        i += 1;
    }
    return t.len;
}

// ---------- to Volt items ----------

// turns the parsed C declarations into Volt items
struct cmapper {
    d: cdecls&;
    names: std::map<str, str> = {}; // struct tag -> Volt name
    span: span;
}

// a Volt type naming `name`
attach fn path_ty(this: cmapper&, name: str) -> ty {
    var segs: std::vec<path_seg> = {};
    put(&segs, { name: name, args: null });
    return { kind: type_kind::PATH({ segs: move segs, span: this.span }), span: this.span };
}

attach fn wrap(this: cmapper&, k: type_kind) -> ty {
    return { kind: move k, span: this.span };
}

// follow typedef names (not the known ones) to what they stand for
attach fn resolve(this: cmapper&, t: ctype&, depth: u32) -> ctype* {
    match (*t) {
        .NAMED(n) => {
            if (known_typedef(n) != null) {
                return t;
            }
            if (depth > 32) {
                return null;
            }
            val next = this.d.typedefs.get(n) ?? return null;
            return this.resolve(next, depth + 1);
        },
        default => { return t; },
    }
}

attach fn void_ptr(this: cmapper&) -> ty {
    return this.wrap(type_kind::PTR(bx(this.path_ty("void"))));
}

// a C function type as an extern "C" Volt fn type; none if a param or the return can't map
attach fn fn_ty(this: cmapper&, ps: std::vec<ctype>&, ret: ctype&, va: bool) -> ty? {
    var params: std::vec<ty> = {};
    for (p&) in ps.items() {
        put(&params, this.ty_of(p) ?? return null);
    }
    val r = this.ty_of(ret) ?? return null;
    return this.wrap(type_kind::FN({ params: move params, c_varargs: va, ret: bx(move r), extern_c: true }));
}

// a C type as a Volt type; none when it can't be used
attach fn ty_of(this: cmapper&, t0: ctype&) -> ty? {
    val t = this.resolve(t0, 0) ?? return null;
    match (*t) {
        .VOID => { return this.path_ty("void"); },
        .BOOL => { return this.path_ty("bool"); },
        .CHAR => { return this.path_ty("i8"); },
        .PRIM(p) => { return this.path_ty(p); },
        .NAMED(n) => { return this.path_ty(known_typedef(n) ?? return null); },
        .STRUCT(tag) => {
            val n = this.names.get(tag) ?? return null;
            return this.path_ty(*n);
        },
        .PTR(inner) => {
            // C pointers may be null: raw T* (a char* is a cstr?, a function pointer an optional fn)
            val r = this.resolve(inner, 0);
            if (r == null) {
                return this.void_ptr();
            }
            val rt = r ?? return null;
            match (*rt) {
                .CHAR => { return this.wrap(type_kind::OPTIONAL(bx(this.path_ty("cstr")))); },
                .FUNC(ps&, ret, va) => {
                    val f = this.fn_ty(ps, ret, va) ?? return this.void_ptr();
                    return this.wrap(type_kind::OPTIONAL(bx(move f)));
                },
                .VOID => { return this.void_ptr(); },
                default => {
                    val x = this.ty_of(rt) ?? return this.void_ptr();
                    return this.wrap(type_kind::PTR(bx(move x)));
                },
            }
        },
        .ARRAY(inner, n) => {
            if (n == null) {
                return null;
            }
            val len: expr = { kind: expr_kind::INT(@cast<u128>(n ?? 0)), span: this.span };
            val it = this.ty_of(inner) ?? return null;
            return this.wrap(type_kind::ARRAY(bx(move it), bx(move len)));
        },
        default => { return null; },
    }
}

// a public item at the import's span
attach fn citem(this: cmapper&, k: item_kind) -> item {
    return { kind: move k, span: this.span, attrs: {}, vis: vis::PUBLIC, generics: {} };
}

// what a header import yields: the Volt items, and the #include lines the generated C needs
struct c_imported {
    items: std::vec<item> = {};
    includes: std::vec<std::string> = {};
}

// the C compiler as a command: $CC split at whitespace (CC="ccache gcc"), else cc. Pushes the words
// onto argv; returns $CC's text for messages. ponytail: no quoting, so a compiler path with spaces
// needs a wrapper script
fn c_command(argv: std::vec<str>&) -> str {
    var text = std::process::env("CC") ?? "cc";
    val start = argv.len;
    var i: usize = 0;
    while (i < text.len) {
        while (i < text.len && (text[i] == ' ' || text[i] == '\t' || text[i] == '\n')) {
            i += 1;
        }
        var e = i;
        while (e < text.len && text[e] != ' ' && text[e] != '\t' && text[e] != '\n') {
            e += 1;
        }
        if (e > i) {
            put(argv, text[i..e]);
        }
        i = e;
    }
    if (argv.len == start) {
        text = "cc";
        put(argv, text);
    }
    return text;
}

// the first "error: ..." line of the C compiler's messages, without its prefix
fn first_error(msg: str) -> str {
    var i: usize = 0;
    while (i < msg.len) {
        var e = i;
        while (e < msg.len && msg[e] != '\n') {
            e += 1;
        }
        val line = msg[i..e];
        if (contains(line, "error")) {
            // what follows the last "error: "
            var at: usize? = null;
            var k: usize = 0;
            while (k + 7 <= line.len) {
                if (starts_at(line, k, "error: ")) {
                    at = k + 7;
                }
                k += 1;
            }
            var rest = line;
            if (at) {
                rest = line[at..line.len];
            }
            return trim(rest);
        }
        i = e + 1;
    }
    return "";
}

fn trim(s: str) -> str {
    var a: usize = 0;
    var b = s.len;
    while (a < b && (s[a] == ' ' || s[a] == '\t' || s[a] == '\r')) {
        a += 1;
    }
    while (b > a && (s[b - 1] == ' ' || s[b - 1] == '\t' || s[b - 1] == '\r')) {
        b -= 1;
    }
    return s[a..b];
}

extern "C" fn realpath(path: cstr, resolved: void*) -> cstr?;
extern "C" fn free(p: void*) -> void;
extern "C" fn strlen(s: cstr) -> usize;

// the canonical path of an existing file, or none
fn real_file(path: str) -> std::string? {
    var p = S(path);
    val r = realpath(p.c_str(), null) ?? return null;
    val out = S(@cast<str>(@slice(@cast<u8*>(r), strlen(r))));
    free(@cast<void*>(r));
    return out;
}

// the --cc arguments the preprocessor needs too, to find and read headers: -I, -D, -U (joined to
// their value or before it) and -isystem, -iquote, -idirafter, -include (and the argument after them)
fn preprocessor_flags(cc_args: std::vec<str>&) -> std::vec<str> {
    var out: std::vec<str> = {};
    var i: usize = 0;
    while (i < cc_args.len) {
        val a = *cc_args.at(i);
        if (a == "-I" || a == "-D" || a == "-U" || a == "-isystem" || a == "-iquote" || a == "-idirafter" || a == "-include") {
            put(&out, a);
            if (i + 1 < cc_args.len) {
                put(&out, *cc_args.at(i + 1));
            }
            i += 1;
        } else if (a.len > 2 && a[0] == '-' && (a[1] == 'I' || a[1] == 'D' || a[1] == 'U')) {
            put(&out, a);
        }
        i += 1;
    }
    return out;
}

// the structs with members Volt can't read (a bitfield, a type it can't parse): libclang says where
// the readable fields are and how big the struct is, and padding fields fill the rest, so Volt's
// own layout is C's and both backends can use them. One it can't place stays partial (only C
// knows its layout: the LLVM backend refuses it)
attach fn lay_out_partial(this: checker&, res: c_imported&, items: std::vec<usize>&, src: str, span: span) -> void {
    if (items.len == 0) {
        return;
    }
    var args: std::vec<str> = {};
    put(&args, "-x");
    put(&args, "c");
    put(&args, "-std=gnu11");
    for (f&) in this.opts.pp_flags.items() {
        put(&args, *f);
    }
    var tu = clang_parse("volt_c_import.c", src, &args);
    if (tu.first_error() != null) {
        return;
    }
    for (k&) in items.items() {
        match (res.items.at(*k).kind) {
            .STRUCT(sd&) => {
                val rt = tu.record_type(sd.c_name ?? continue) ?? continue;
                val size = clang::clang_Type_getSizeOf(rt);
                if (size <= 0) {
                    continue;
                }
                if (sd.c_union) {
                    // its members all sit at 0: one padding member as big and as aligned as C's
                    // union stands for the ones Volt can't read
                    val align = clang::clang_Type_getAlignOf(rt);
                    if (align <= 0 || align > 16 || size % align != 0) {
                        continue;
                    }
                    var pads: u32 = 0;
                    put(&sd.fields, this.pad_field(&pads, @cast<u64>(align), @cast<u64>(size / align), span));
                    sd.c_partial = false;
                    continue;
                }
                var offs: std::vec<u64> = {};
                var sizes: std::vec<u64> = {};
                var known = true;
                var overlap = false;
                var end: u64 = 0;
                for (f&) in sd.fields.items() {
                    var n = S(f.name);
                    val bits = clang::clang_Type_getOffsetOf(rt, n.c_str());
                    val fsize = field_size(rt, f.name);
                    if (bits < 0 || bits % 8 != 0 || fsize <= 0) {
                        known = false;
                        break;
                    }
                    val off = @cast<u64>(bits / 8);
                    overlap = overlap || off < end;
                    end = off + @cast<u64>(fsize);
                    put(&offs, off);
                    put(&sizes, @cast<u64>(fsize));
                }
                if (!known) {
                    continue;
                }
                if (overlap) {
                    // fields that share bytes (an anonymous union member): the LLVM backend places
                    // each at its offset in a block of C's size and alignment
                    val align = clang::clang_Type_getAlignOf(rt);
                    if (align <= 0) {
                        continue;
                    }
                    sd.c_offsets = move offs;
                    sd.c_size = @cast<u64>(size);
                    sd.c_align = @cast<u64>(align);
                    sd.c_partial = false;
                    continue;
                }
                // padding fields fill the gaps, so Volt's own layout is C's
                var fields: std::vec<field> = {};
                var at: u64 = 0;
                var pads: u32 = 0;
                for (i) in 0..sd.fields.len {
                    this.pad_fields(at, *offs.at(i), &pads, span, &fields);
                    put(&fields, copy *sd.fields.at(i));
                    at = *offs.at(i) + *sizes.at(i);
                }
                this.pad_fields(at, @cast<u64>(size), &pads, span, &fields);
                sd.fields = move fields;
                sd.c_partial = false;
            },
            default => {},
        }
    }
}

// run the C preprocessor over the includes; its output, or a message
attach fn preprocess(this: checker&, src: str, extra: str, span: span) -> compile_error!std::string {
    var args: std::vec<str> = {};
    val cc = c_command(&args);
    for (f&) in this.opts.pp_flags.items() {
        put(&args, *f);
    }
    val rest: str[6] = { "-E", extra, "-std=gnu11", "-x", "c", "-" };
    for (a) in rest {
        put(&args, a);
    }
    val r = std::process::capture(args.items(), src) catch |e| {
        return fail(span, fmt("can't run the C compiler '{}' to read the headers", S(cc)));
    };
    if (r.code != 0) {
        return fail(span, fmt("the C compiler couldn't read these headers: {}", S(first_error(r.err.as_str()))));
    }
    return copy r.out;
}

// read `headers` (local ones next to dir, others from the system) into Volt items
attach fn import_headers(this: checker&, headers: std::vec<std::string>&, dir: str?, span: span) -> compile_error!c_imported {
    var res: c_imported = {};
    var src: std::string = {};
    for (h&) in headers.items() {
        var line: std::string = {};
        var local: std::string? = null;
        if (dir) {
            var p = S(dir);
            p.push('/');
            p.append(h.as_str());
            local = real_file(p.as_str());
        }
        if (local) {
            line.append("#include \"");
            line.append(local.as_str());
            line.append("\"");
        } else {
            line.append("#include <");
            line.append(h.as_str());
            line.append(">");
        }
        src.append(line.as_str());
        src.push('\n');
        put(&res.includes, move line);
    }
    val decls = try this.preprocess(src.as_str(), "-P", span);
    val macros = try this.preprocess(src.as_str(), "-dM", span);
    // the token texts point into these, and so do the items made from them
    put(&this.c_texts, move decls);
    val dtext = this.c_texts.at(this.c_texts.len - 1).as_str();
    put(&this.c_texts, move macros);
    val mtext = this.c_texts.at(this.c_texts.len - 1).as_str();
    var d: cdecls = {};
    parse_decls(dtext, &d);
    try this.c_macros(&d, mtext);
    this.c_items(&d, &res, span);
    return res;
}

// reads C declarations (preprocessed) into d; function bodies are skipped
fn parse_decls(text: str, d: cdecls&) -> void {
    val toks = c_lex(text);
    val all = toks.items();
    // the declarations, one at a time
    var i: usize = 0;
    while (i < toks.len) {
        val end = decl_end(all, i);
        var p: cparser = { t: all[i..end], i: 0, d: d };
        p.top();
        i = end;
        if (i < toks.len && is_p(toks.at(i), "{")) {
            // a function body: skip it
            var depth: i32 = 0;
            while (i < toks.len) {
                match (*toks.at(i)) {
                    .P(q) => {
                        if (q == "{") {
                            depth += 1;
                        } else if (q == "}") {
                            depth -= 1;
                        }
                    },
                    default => {},
                }
                i += 1;
                if (depth == 0) {
                    break;
                }
            }
        } else {
            i += 1;
        }
    }
}

// an object-like #define: its name and body tokens
struct cdefine {
    name: str;
    body: std::vec<ctok>;
}

// numeric object-like #defines (EOF, SEEK_SET, RAND_MAX, M_PI...). They may use macros defined
// after them (INT_MAX is __INT_MAX__), so repeat until nothing new resolves; _names stay hidden
attach fn c_macros(this: checker&, d: cdecls&, macros: str) -> compile_error!void {
    var defs: std::vec<cdefine> = {};
    var i: usize = 0;
    while (i < macros.len) {
        var e = i;
        while (e < macros.len && macros[e] != '\n') {
            e += 1;
        }
        val line = macros[i..e];
        i = e + 1;
        if (!starts_with(line, "#define ")) {
            continue;
        }
        val rest = line[8..line.len];
        var n: usize = 0;
        while (n < rest.len && (c_is_alnum(rest[n]) || rest[n] == '_')) {
            n += 1;
        }
        val body = rest[n..rest.len];
        if (body.len > 0 && body[0] == '(') {
            continue;
        }
        put(&defs, { name: rest[0..n], body: c_lex(body) });
    }
    var known: std::map<str, bool> = {};
    loop {
        var progress = false;
        for (df&) in defs.items() {
            if (known.get(df.name) != null || d.env.get(df.name) != null) {
                continue;
            }
            val v = const_eval(df.body.items(), &d.env);
            if (v) {
                known.put(df.name, true);
                d.env.put(df.name, v);
                if (!starts_with(df.name, "_")) {
                    put(&d.consts, { name: df.name, v: v });
                }
                progress = true;
            }
        }
        if (!progress) {
            break;
        }
    }
}

// one Volt item per C struct, fn, variable and constant
attach fn c_items(this: checker&, d: cdecls&, res: c_imported&, span: span) -> void {
    var m: cmapper = { d: d, span: span };
    var taken: std::map<str, bool> = {};
    var c_names: std::map<str, str> = {};
    // one Volt struct per C struct: named by its first typedef, else by its tag (also when the
    // typedef is reserved and the tag isn't: __sigval_t, union sigval)
    for (s&) in d.structs.items() {
        var name: str = "";
        var c: str = "";
        val anon = s.tag.len > 0 && s.tag[0] == '#';
        val td = d.typedef_of.get(s.tag);
        var by_tag = true;
        if (td) {
            by_tag = starts_with(*td, "__") && !anon && !starts_with(s.tag, "__");
            name = *td;
            c = *td;
        } else if (anon) {
            continue; // anonymous and never typedef'd: unreachable
        }
        if (by_tag) {
            name = s.tag;
            var cn = S("struct ");
            if (s.is_union) {
                cn = S("union ");
            }
            cn.append(s.tag);
            c = this.intern(move cn);
        }
        if (starts_with(name, "__") || taken.get(name) != null) {
            continue;
        }
        taken.put(name, true);
        m.names.put(s.tag, name);
        c_names.put(s.tag, c);
    }
    // an anonymous struct or union typing a named field is OUTER_FIELD: a typedef of the field's
    // __typeof__ in the generated C (outer ones first, so nested ones can name them)
    loop {
        var progress = false;
        for (s&) in d.structs.items() {
            if (m.names.get(s.tag) != null) {
                continue;
            }
            val link = d.anon_in.get(s.tag) ?? continue;
            val outer = m.names.get(link.outer) ?? continue;
            val outer_c = c_names.get(link.outer) ?? continue;
            var nm = S(*outer);
            nm.push('_');
            nm.append(link.field);
            val name = this.intern(move nm);
            if (taken.get(name) != null) {
                continue;
            }
            taken.put(name, true);
            var td = S("typedef __typeof__(((");
            td.append(*outer_c);
            td.append(" *)0)->");
            td.append(link.field);
            td.append(") ");
            td.append(name);
            td.push(';');
            put(&res.includes, move td);
            m.names.put(s.tag, name);
            c_names.put(s.tag, name);
            d.typedefs.put(name, ctype::STRUCT(s.tag));
            progress = true;
        }
        if (!progress) {
            break;
        }
    }
    // each bitfield's accessors: C reads and writes it, so neither backend needs its bits
    var protos = S("");
    for (s&) in d.structs.items() {
        val name = m.names.get(s.tag) ?? continue;
        val c = c_names.get(s.tag) ?? continue;
        if (s.fields) {
            for (f&) in s.fields.items() {
                val ty = f.bits ?? continue;
                var get = S("static inline ");
                get.append(ty);
                get.push(' ');
                get.append(*name);
                get.append("_get_");
                get.append(f.bit_name);
                get.append("(const ");
                get.append(*c);
                get.append(" *s)");
                var set = S("static inline void ");
                set.append(*name);
                set.append("_set_");
                set.append(f.bit_name);
                set.push('(');
                set.append(*c);
                set.append(" *s, ");
                set.append(ty);
                set.append(" v)");
                protos.append(get.as_str());
                protos.append(";\n");
                protos.append(set.as_str());
                protos.append(";\n");
                get.append(" { return s->");
                get.append(f.bit_name);
                get.append("; }");
                set.append(" { s->");
                set.append(f.bit_name);
                set.append(" = v; }");
                put(&res.includes, move get);
                put(&res.includes, move set);
            }
        }
    }
    if (protos.len() > 0) {
        put(&this.c_texts, move protos);
        parse_decls(this.c_texts.at(this.c_texts.len - 1).as_str(), d);
    }
    var partial_items: std::vec<usize> = {};
    for (s&) in d.structs.items() {
        val name = m.names.get(s.tag) ?? continue;
        val c = c_names.get(s.tag) ?? continue;
        var fields: std::vec<field> = {};
        var partial = false;
        if (s.fields) {
            for (f&) in s.fields.items() {
                val t = m.ty_of(&f.ty);
                if (f.name.len == 0 || t == null) {
                    partial = true; // a member Volt can't read: only C knows the layout
                    continue;
                }
                put(&fields, { name: f.name, ty: t ?? @panic("ty"), fallback: null, vis: vis::PUBLIC, span: span });
            }
        }
        put(&res.items, m.citem(item_kind::STRUCT({ name: *name, spec: null, fields: move fields, is_extern: true, is_comptime: false, c_name: *c, c_partial: partial, c_union: s.is_union })));
        if (partial && s.fields != null) {
            put(&partial_items, res.items.len - 1);
        }
    }
    // libclang sees what the C compiler will: the headers, then the typedefs and accessors above
    var all_c = S("");
    for (inc&) in res.includes.items() {
        all_c.append(inc.as_str());
        all_c.push('\n');
    }
    this.lay_out_partial(res, &partial_items, all_c.as_str(), span);
    // every other typedef is a type name too: pointers, integers, function pointers, a struct's
    // second name (one Volt can't map, or whose name is taken, is skipped)
    for (n) in d.typedef_order.items() {
        if (starts_with(n, "__") || taken.get(n) != null) {
            continue;
        }
        val t = d.typedefs.get(n) ?? continue;
        val vt = m.ty_of(t) ?? continue;
        taken.put(n, true);
        put(&res.items, m.citem(item_kind::ALIAS(n, move vt)));
    }
    // functions (the first declaration wins); one with a param or return type Volt can't use is skipped
    var seen_fns: std::map<str, bool> = {};
    for (f&) in d.fns.items() {
        if (seen_fns.get(f.name) != null) {
            continue;
        }
        seen_fns.put(f.name, true);
        var params: std::vec<param> = {};
        var ok = true;
        for (i) in 0..f.params.len {
            val p = f.params.at(i);
            val t = m.ty_of(&p.ty);
            if (t == null) {
                ok = false;
                break;
            }
            var pn = p.name;
            if (pn == null) {
                var a = S("a");
                a.append_uint(@cast<u64>(i));
                pn = this.intern(move a);
            }
            put(&params, { name: pn ?? "", ty: move t, fallback: null, mutable: false, is_static: false, is_comptime: false, span: span });
        }
        if (!ok) {
            continue;
        }
        val ret = m.ty_of(&f.ret) ?? continue;
        put(&res.items, m.citem(item_kind::FN({ name: f.name, spec: null, params: move params, c_varargs: f.variadic, ret: move ret, body: null, is_async: false, is_comptime: false, extern_abi: C_HEADER, is_export: false, is_attach: false })));
    }
    // extern variables, bound to their C names
    for (v&) in d.vars.items() {
        val t = m.ty_of(&v.ty) ?? continue;
        val pt: pat = { kind: pat_kind::BIND(v.name), span: span };
        put(&res.items, m.citem(item_kind::GLOBAL({ mutable: true, is_comptime: false, is_static: false, pat: pt, ty: move t, init: null, span: span, c_name: v.name })));
    }
    // constants: an int gets the first of i32, u32, i64, u64 that its suffixes allow and its value fits,
    // a float f64; a negative value is `-literal`
    for (k&) in d.consts.items() {
        if (starts_with(k.name, "__")) {
            continue;
        }
        val v = k.v;
        var tn: str = "";
        var lit: expr_kind = expr_kind::NULL;
        var neg = false;
        if (!v.is_float) {
            val x = v.v;
            if (!v.unsigned && !v.long && x >= -2147483648 && x <= 2147483647) {
                tn = "i32";
            } else if (v.unsigned && !v.long && x >= 0 && x <= 4294967295) {
                tn = "u32";
            } else if (!v.unsigned && x >= -9223372036854775807 - 1 && x <= 9223372036854775807) {
                tn = "i64";
            } else if (x >= 0 && x <= 18446744073709551615) {
                tn = "u64";
            } else {
                continue;
            }
            neg = x < 0;
            if (neg) {
                lit = expr_kind::INT(@cast<u128>(-x));
            } else {
                lit = expr_kind::INT(@cast<u128>(x));
            }
        } else {
            tn = "f64";
            neg = v.f < 0.0 || (v.f == 0.0 && 1.0 / v.f < 0.0);
            if (neg) {
                lit = expr_kind::FLOAT(-v.f);
            } else {
                lit = expr_kind::FLOAT(v.f);
            }
        }
        var init: expr = { kind: move lit, span: span };
        if (neg) {
            init = { kind: expr_kind::UNARY(unop::NEG, bx(move init)), span: span };
        }
        val pt: pat = { kind: pat_kind::BIND(k.name), span: span };
        put(&res.items, m.citem(item_kind::GLOBAL({ mutable: false, is_comptime: false, is_static: false, pat: pt, ty: m.path_ty(tn), init: move init, span: span, c_name: null })));
    }
}

// `use { "a.h", "b.h" } as alias;`: the headers' declarations as namespace alias
attach fn import_c(this: checker&, headers: std::vec<std::string>&, alias: str, ns: u32, span: span) -> compile_error!void {
    val file = this.files.at(@cast<usize>(span.file)).name;
    // headers next to the source file first; std (no file) only sees system headers
    var dir: str? = null;
    if (!(file.len > 0 && file[0] == '<')) {
        var slash: usize? = null;
        for (i) in 0..file.len {
            if (file[i] == '/') {
                slash = i;
            }
        }
        if (slash) {
            if (slash > 0) {
                dir = file[0..slash];
            } else {
                dir = "/";
            }
        } else {
            dir = ".";
        }
    }
    val imp = try this.import_headers(headers, dir, span);
    for (inc&) in imp.includes.items() {
        var have = false;
        for (x&) in this.c_includes.items() {
            if (*x == inc.as_str()) {
                have = true;
            }
        }
        if (!have) {
            put(&this.c_includes, this.intern(copy *inc));
        }
    }
    val n = this.ns_child(ns, alias);
    for (it&) in imp.items.items() {
        var kind = 0;
        var key_name: str = "";
        var name: str = "";
        match (it.kind) {
            .FN(f) => {
                kind = 0;
                key_name = f.name;
                name = f.name;
            },
            .STRUCT(s) => {
                kind = 1;
                key_name = s.c_name ?? "";
                name = s.name;
            },
            .GLOBAL(l) => {
                match (l.pat.kind) {
                    .BIND(b) => {
                        kind = 2;
                        key_name = b;
                        name = b;
                    },
                    default => { continue; },
                }
            },
            .ALIAS(a, t) => {
                kind = 3;
                key_name = a;
                name = a;
            },
            default => { continue; },
        }
        // the same C symbol imported again (another namespace, or std and the user) is one decl
        var k = S("");
        k.append_uint(@cast<u64>(kind));
        k.push(':');
        k.append(key_name);
        val have = this.c_imports.get(k.as_str());
        if (have) {
            val d = *have;
            val names = &this.ns(n).names;
            val l = names.get(name);
            if (l) {
                var dup = false;
                for (x&) in this.list(*l).items() {
                    if (*x == d) {
                        dup = true;
                    }
                }
                if (!dup) {
                    put(this.list(*l), d);
                }
            } else {
                names.put(name, this.new_list(nodes(d)));
            }
        } else {
            this.c_imports.put(this.intern(move k), @cast<u32>(this.decls.len));
            put(&this.owned_items, bx(copy *it));
            val kept = this.owned_items.at(this.owned_items.len - 1);
            this.importing_c = true;
            val r = this.collect_item(*kept, n, null);
            this.importing_c = false;
            try r;
        }
    }
}
