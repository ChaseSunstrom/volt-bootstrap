// C header import: a port of bootstrap/cimport.rs. `use { "stdio.h" } as c;` runs the C preprocessor over
// the headers and reads back what maps to Volt: functions (static inline ones too), structs, enum
// constants, numeric #defines and extern variables, as ordinary items of namespace `c`. The headers
// are #included in the generated C, so calls go through C's own prototypes and structs keep C's
// layout. A union is a struct whose fields share offset 0; a bitfield gets two static inline C
// functions, S_get_F and S_set_F, next to the #include (C does the bit work on both backends), and so
// does a function taking or giving a long double (an f64 to Volt) or a _Complex (a cf32 or cf64
// { re, im }): a wrapper converting them. A named enum is a Volt enum that converts to and from
// integers. The parser is tolerant: a declaration it can't read or map (va_list...) is skipped, not
// an error. C pointers can be null: raw T*, a char* is a cstr?, a function pointer an optional fn.
use std::mem;

// the extern_abi of fns declared by an imported header (C's own prototype is used)
val C_HEADER: str = "C header";

// a C token; a string literal keeps the text between its quotes (an asm label's symbol)
enum ctok {
    ID: str,
    NUM: str,
    STR: str,
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
                put(&out, ctok::STR(body));
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
    ENUM: str,    // by tag, the same way
    PTR: std::box<ctype>,
    ARRAY: (std::box<ctype>, u64?),
    FUNC: (std::vec<ctype>, std::box<ctype>, bool),
    LDOUBLE,      // long double: an f64 through a wrapper
    COMPLEX: str, // _Complex of its real type's C name (float, double, long double): through a wrapper
    VA_LIST,      // va_list: a function taking one last is called with varargs (va_wrapper)
    BAD,          // _Float16...: can't be used by value
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
    stat: bool = false; // static: defined in the header, no symbol of its own
    label: str? = null; // its symbol, when an asm label names it (glibc's __REDIRECT)
}

struct cvar {
    name: str;
    ty: ctype;
}

struct cconst {
    name: str;
    v: cnum;
    in_enum: str? = null; // an enumerator: its enum's tag
}

// a C enum's enumerators that have values, by tag (anonymous ones get a made-up tag)
struct cenum {
    tag: str;
    names: std::vec<str> = {};
    values: std::vec<i128> = {};
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
    enums: std::vec<cenum> = {};
    enum_typedef_of: std::map<str, str> = {}; // enum tag -> first typedef naming it
    fns: std::vec<cfn> = {};
    vars: std::vec<cvar> = {};
    // counter for made-up tags of anonymous structs
    anon: u32 = 0;
    last_params: std::vec<str?> = {}; // names in the param list read last (the declared fn's own)
    kr: bool = false;                    // ...which was a K&R identifier list
    label: str? = null;                  // the asm label read last (the declared fn's)
    names: std::vec<std::string> = {}; // made-up names (anonymous tags) the others point into
    anon_in: std::map<str, anon_field> = {}; // anonymous tag -> the named field it types
    fn_macros: std::vec<str> = {};     // function-like #defines (MAX(a, b)): called per use
}

// a made-up tag for an anonymous struct or enum: prefix and a number
attach fn made_up(this: cdecls&, prefix: str) -> str {
    this.anon += 1;
    var a = S(prefix);
    a.append_uint(@cast<u64>(this.anon));
    put(&this.names, move a);
    return this.names.at(this.names.len - 1).as_str();
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
    body: bool = false; // a function body follows (a K&R definition's names are its parameters)
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
    val words: str[22] = { "const", "__const", "volatile", "__volatile__", "restrict", "__restrict", "__restrict__", "inline", "__inline", "__inline__", "extern", "register", "_Noreturn", "__extension__", "auto", "_Nonnull", "_Nullable", "_Null_unspecified", "constexpr", "", "", "" };
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
    // C23's [[attribute]]
    if (this.is("[") && this.i + 1 < this.t.len && is_p(&this.t[this.i + 1], "[")) {
        if (!this.skip_group()) {
            return null;
        }
        return true;
    }
    val n = this.peek_id() ?? return false;
    if (n == "__attribute__" || n == "__attribute" || n == "__asm__" || n == "__asm" || n == "asm" || n == "__declspec" || n == "_Alignas" || n == "alignas" || n == "__typeof__") {
        this.i += 1;
        val start = this.i;
        if (this.is("(") && !this.skip_group()) {
            return null;
        }
        if (n == "__asm__" || n == "__asm" || n == "asm") {
            // a label: its string literals joined
            var label = S("");
            for (k&) in this.t[start..this.i] {
                match (*k) {
                    .STR(x) => { label.append(x); },
                    default => {},
                }
            }
            put(&this.d.names, move label);
            this.d.label = this.d.names.at(this.d.names.len - 1).as_str();
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
    return null;
}

// declaration specifiers -> base type; sets `stat` for static/thread-local storage
attach fn specs(this: cparser&, stat: bool&) -> ctype? {
    var signed = false;
    var unsigned = false;
    var short = false;
    var longs = 0;
    var int = false;
    var complex = false;
    var base: ctype? = null;
    loop {
        if (this.skip_noise() ?? return null) {
            continue;
        }
        val n = this.peek_id() ?? break;
        val seen = base != null || signed || unsigned || short || longs > 0 || int;
        if (n == "static" || n == "_Thread_local" || n == "thread_local" || n == "__thread") {
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
        } else if (n == "_Bool" || (n == "bool" && !seen && this.d.typedefs.get("bool") == null)) {
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
        } else if (n == "_Complex" || n == "__complex__") {
            complex = true;
        } else if (n == "__builtin_va_list") {
            base = ctype::VA_LIST;
        } else if (n == "_Float32x" || n == "_Float64x" || n == "_Float128x" || n == "_Float16") {
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
                tag = this.d.made_up("#anon");
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
            var tag: str = "";
            val t = this.peek_id();
            if (t) {
                tag = t;
                this.i += 1;
            } else {
                tag = this.d.made_up("#enum");
            }
            if (this.is("{")) {
                if (!this.enumerators(tag)) {
                    return null;
                }
            }
            base = ctype::ENUM(tag);
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
                    if (complex) {
                        return ctype::COMPLEX("long double");
                    }
                    return ctype::LDOUBLE;
                }
                if (complex && p == "f64") {
                    return ctype::COMPLEX("double");
                }
                if (complex && p == "f32") {
                    return ctype::COMPLEX("float");
                }
            },
            default => {},
        }
        if (complex) {
            return ctype::BAD; // GNU's complex integers
        }
        return copy base;
    }
    if (complex || !(signed || unsigned || short || longs > 0 || int)) {
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

// `{ A, B = 5, ... }` of enum `tag`: each constant goes into consts and env, and into its cenum
attach fn enumerators(this: cparser&, tag: str) -> bool {
    if (!this.eat("{")) {
        return false;
    }
    put(&this.d.enums, { tag: tag });
    val at = this.d.enums.len - 1;
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
            put(&this.d.consts, { name: name, v: value, in_enum: tag });
            put(&this.d.enums.at(at).names, name);
            put(&this.d.enums.at(at).values, value.v);
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
    val words: str[24] = { "void", "char", "short", "int", "long", "float", "double", "signed", "unsigned", "_Bool", "struct", "union", "enum", "const", "volatile", "__const", "__extension__", "__attribute__", "__builtin_va_list", "__signed__", "__int128", "_Float128", "__restrict", "_Complex" };
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

// t[a..b] (a parenthesized list after a function's name) is a K&R definition's names, and its
// parameters' declarations follow it, up to the body
fn kr_head(t: ctok[..], a: usize, b: usize) -> bool {
    if (a < 2) {
        return false;
    }
    match (t[a - 2]) {
        .ID(n) => {
            val not_names: str[10] = { "typeof", "__typeof__", "__typeof", "typeof_unqual", "__attribute__", "__attribute", "_Alignas", "alignas", "sizeof", "__declspec" };
            for (w) in not_names {
                if (n == w) {
                    return false;
                }
            }
        },
        default => { return false; },
    }
    match (t[b + 1]) {
        .ID(n) => {
            if (n == "__attribute__" || n == "__asm__" || n == "__asm" || n == "asm") {
                return false;
            }
        },
        default => { return false; },
    }
    var names = b > a;
    var k = a;
    while (k < b) {
        match (t[k]) {
            .ID(n) => { names = names && (k - a) % 2 == 0 && !is_param_word(n) && known_typedef(n) == null; },
            .P(p) => { names = names && p == "," && (k - a) % 2 == 1; },
            default => { names = false; },
        }
        k += 1;
    }
    return names;
}

// a K&R definition's parameter list: names only (no type words, no typedef names)
fn is_id_list(t: ctok[..], d: cdecls&) -> bool {
    if (t.len == 0) {
        return false;
    }
    for (part) in split_top(t, ",").items() {
        if (part.len != 1) {
            return false;
        }
        match (part[0]) {
            .ID(n) => {
                if (d.typedefs.get(n) != null || known_typedef(n) != null || is_param_word(n) || n == "bool") {
                    return false;
                }
            },
            default => { return false; },
        }
    }
    return true;
}

// a K&R definition's parameter declarations (int a; char *b;), after its name list: each name's
// type, as a caller passes it (char and short as int, float as double: there's no prototype)
attach fn kr_params(this: cparser&, dc: cdecl&) -> void {
    var names: std::vec<str?> = copy this.d.last_params;
    match (dc.ty) {
        .FUNC(ps&, r, v) => {
            while (this.peek() != null) {
                var stat = false;
                val base = this.specs(&stat) ?? return;
                loop {
                    val pd = this.declarator(copy base) ?? return;
                    val pn = pd.name ?? "";
                    for (k) in 0..names.len {
                        if (pn.len > 0 && (*names.at(k) ?? "") == pn) {
                            var ty = copy pd.ty;
                            match (pd.ty) {
                                .ARRAY(inner, n) => { ty = ctype::PTR(copy inner); },
                                .PRIM(p) => {
                                    if (p == "i8" || p == "u8" || p == "i16" || p == "u16") {
                                        ty = ctype::PRIM("i32");
                                    } else if (p == "f32") {
                                        ty = ctype::PRIM("f64");
                                    }
                                },
                                .CHAR => { ty = ctype::PRIM("i32"); },
                                .BOOL => { ty = ctype::PRIM("i32"); },
                                default => {},
                            }
                            *ps.at(k) = move ty;
                        }
                    }
                    if (!this.eat(",")) {
                        break;
                    }
                }
                if (!this.eat(";")) {
                    return;
                }
            }
        },
        default => {},
    }
    this.d.last_params = move names;
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
    this.d.kr = false;
    if (toks.len == 0 || only_void(toks)) {
        return out;
    }
    if (this.body && is_id_list(toks, this.d)) {
        // K&R: f(a, b) int a; ...: names only; their types come from the declarations after it
        for (part) in split_top(toks, ",").items() {
            match (part[0]) {
                .ID(n) => { put(&out, { name: n, ty: ctype::PRIM("i32") }); },
                default => {},
            }
        }
        this.d.kr = true;
        this.d.last_params = {};
        for (p&) in out.items() {
            put(&this.d.last_params, p.name);
        }
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
    val first = this.peek_id() ?? "";
    if (first == "_Static_assert" || first == "static_assert") {
        return;
    }
    // C23's constexpr: a constant (read like an enumerator), not static data
    var is_constexpr = false;
    for (t&) in this.t {
        match (*t) {
            .ID(n) => {
                if (n == "constexpr") {
                    is_constexpr = true;
                }
            },
            default => {},
        }
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
        this.d.label = null;
        var dc = this.declarator(copy base) ?? return;
        val name = dc.name ?? return;
        if (this.eat("=")) {
            if (is_constexpr) {
                val v = const_eval(this.t[this.i..this.t.len], &this.d.env);
                if (v) {
                    this.d.env.put(name, v);
                    put(&this.d.consts, { name: name, v: v });
                }
            }
            return; // initialized variables in headers are static data, not imports
        }
        if (this.d.kr) {
            this.kr_params(&dc);
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
                .ENUM(tag) => {
                    if (this.d.enum_typedef_of.get(tag) == null) {
                        this.d.enum_typedef_of.put(tag, name);
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
                    put(&this.d.fns, { name: name, params: move cps, ret: copy *ret.ptr, variadic: variadic, stat: stat, label: this.d.label });
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

// end of the declaration starting at i: its `;`, or the `{` of a function body (a K&R one's after
// its parameter declarations: f(a, b) int a; int b; {)
fn decl_end(t: ctok[..], start: usize) -> usize {
    var depth: i32 = 0;
    var i = start;
    var open: usize = 0;
    while (i < t.len) {
        match (t[i]) {
            .P(p) => {
                if (p == "(" || p == "[") {
                    if (depth == 0) {
                        open = i;
                    }
                    depth += 1;
                } else if (p == ")" || p == "]") {
                    depth -= 1;
                    if (depth == 0 && p == ")" && i + 1 < t.len && kr_head(t, open + 1, i)) {
                        var j = i + 1;
                        while (j < t.len && !is_p(&t[j], "{") && !is_p(&t[j], "}")) {
                            j += 1;
                        }
                        if (j < t.len && is_p(&t[j], "{") && is_p(&t[j - 1], ";")) {
                            return j;
                        }
                    }
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
    enum_names: std::map<str, str> = {}; // enum tag -> Volt name (a named one's)
    enum_ints: std::map<str, str> = {};  // enum tag -> the integer type its values take
    in_fn: bool = false;                 // mapping a function pointer's type
    complex: std::vec<str> = {};         // the complex structs wrappers use: cf32, cf64
    cf32: str = "cf32";                  // their Volt names (with _ added past a header's own)
    cf64: str = "cf64";
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

// a C function type as an extern "C" Volt fn type; none if a param or the return can't map. Its
// enums are their integers, so a Volt fn written against them passes as one
attach fn fn_ty(this: cmapper&, ps: std::vec<ctype>&, ret: ctype&, va: bool) -> ty? {
    val was = this.in_fn;
    this.in_fn = true;
    val f = this.fn_ty_in(ps, ret, va);
    this.in_fn = was;
    return f;
}

attach fn fn_ty_in(this: cmapper&, ps: std::vec<ctype>&, ret: ctype&, va: bool) -> ty? {
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
        .ENUM(tag) => {
            // a named one is its Volt enum; an anonymous one is the integer its values take
            val n = this.enum_names.get(tag);
            if (n != null && !this.in_fn) {
                return this.path_ty(*n);
            }
            val k = this.enum_ints.get(tag) ?? return this.path_ty("i32");
            return this.path_ty(*k);
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

// does a function taking or giving t by value need a wrapper (a long double, a _Complex)?
attach fn needs_wrap(this: cmapper&, t: ctype&) -> bool {
    val r = this.resolve(t, 0) ?? return false;
    match (*r) {
        .LDOUBLE => { return true; },
        .COMPLEX(e) => { return true; },
        default => { return false; },
    }
}

// the complex struct standing for C's complex of real type e: cf32 for float, else cf64 (volt_cf32,
// volt_cf64 to C)
fn complex_name(e: str) -> str {
    if (e == "float") {
        return "cf32";
    }
    return "cf64";
}

// complex struct n's Volt name
attach fn complex_volt(this: cmapper&, n: str) -> str {
    if (n == "cf32") {
        return this.cf32;
    }
    return this.cf64;
}

// t as a wrapper's parameter or result: a long double is an f64, a complex its struct
attach fn wrap_ty(this: cmapper&, t: ctype&) -> ty? {
    val r = this.resolve(t, 0) ?? return null;
    match (*r) {
        .LDOUBLE => { return this.path_ty("f64"); },
        .COMPLEX(e) => {
            val n = complex_name(e);
            var have = false;
            for (x&) in this.complex.items() {
                have = have || *x == n;
            }
            if (!have) {
                put(&this.complex, n);
            }
            return this.path_ty(this.complex_volt(n));
        },
        default => { return this.ty_of(t); },
    }
}

// is t a pointer c_text spells itself (by its pointee's width, not the header's name)?
fn spelled_ptr(t: ctype&) -> bool {
    match (*t) {
        .PTR(x) => { return true; },
        default => { return false; },
    }
}

// t as C text for a wrapper's declaration (an integer by its width); none for one it can't write
attach fn c_text(this: cmapper&, t: ctype&, c_names: std::map<str, str>&) -> std::string? {
    match (*t) {
        .VOID => { return S("void"); },
        .BOOL => { return S("_Bool"); },
        .CHAR => { return S("char"); },
        .PRIM(p) => {
            val vs: str[12] = { "i8", "u8", "i16", "u16", "i32", "u32", "i64", "u64", "i128", "u128", "f32", "f64" };
            val cs: str[12] = { "signed char", "unsigned char", "short", "unsigned short", "int", "unsigned int", "long long", "unsigned long long", "__int128", "unsigned __int128", "float", "double" };
            for (i) in 0..12 {
                if (vs[i] == p) {
                    return S(cs[i]);
                }
            }
            return null;
        },
        .NAMED(n) => { return S(n); },
        .STRUCT(tag) => {
            val c = c_names.get(tag) ?? return null;
            return S(*c);
        },
        .ENUM(tag) => {
            if (tag[0] != '#') {
                return fmt("enum {}", S(tag));
            }
            val td = this.d.enum_typedef_of.get(tag) ?? return S("int");
            return S(*td);
        },
        .PTR(inner) => {
            var s = this.c_text(inner, c_names) ?? return null;
            s.append(" *");
            return s;
        },
        .LDOUBLE => { return S("long double"); },
        .COMPLEX(e) => { return fmt("{} _Complex", S(e)); },
        default => { return null; },
    }
}

// a static inline C function `volt_cw_NAME` calling fn f with its long doubles as doubles and its
// complexes as volt_cf32/volt_cf64 { re, im }; none if a type can't be written. It calls f through a
// declaration of its own bound to f's symbol (volt_cr_NAME; its asm label's, as glibc's __REDIRECT
// gives one): a header may declare f only under a feature macro the program's C doesn't set
// (python's strtold_l), and an unused wrapper is never compiled into a call; a static f, only its
// header's, by its name. A pointer c_text spells by width (long long * for a long *) passes as a
// void *, which C converts to f's own
attach fn wrapper(this: cmapper&, f: cfn&, c_names: std::map<str, str>&) -> std::string? {
    var params = S("");
    var args = S("");
    var orig = S(""); // f's own parameter types
    for (i) in 0..f.params.len {
        val p = f.params.at(i);
        val r = this.resolve(&p.ty, 0) ?? return null;
        if (i > 0) {
            params.append(", ");
            args.append(", ");
        }
        var a = S("volt_a");
        a.append_uint(@cast<u64>(i));
        if (i > 0) {
            orig.append(", ");
        }
        match (*r) {
            .LDOUBLE => {
                params.append("double");
                args.append(a.as_str());
                orig.append("long double");
            },
            .COMPLEX(e) => {
                params.append("volt_");
                params.append(complex_name(e));
                args.append(fmt4("__builtin_complex(({}){}.re, ({}){}.im)", S(e), copy a, S(e), copy a).as_str());
                orig.append(fmt("{} _Complex", S(e)).as_str());
            },
            default => {
                val t = this.c_text(&p.ty, c_names) ?? return null;
                params.append(t.as_str());
                if (spelled_ptr(&p.ty)) {
                    args.append("(void *)");
                }
                args.append(a.as_str());
                orig.append(t.as_str());
            },
        }
        params.push(' ');
        params.append(a.as_str());
    }
    if (f.params.len == 0) {
        params.append("void");
        orig.append("void");
    }
    var callee = S(f.name);
    if (!f.stat) {
        callee = fmt("volt_cr_{}", S(f.name));
    }
    var call = fmt2("{}({})", copy callee, move args);
    if (spelled_ptr(&f.ret)) {
        call = fmt("(void *){}", move call);
    }
    var ret = S("double");
    var orig_ret = S("long double");
    var body = fmt("return {};", copy call);
    val rr = this.resolve(&f.ret, 0) ?? return null;
    match (*rr) {
        .VOID => {
            ret = S("void");
            orig_ret = S("void");
            body = fmt("{};", copy call);
        },
        .LDOUBLE => {},
        .COMPLEX(e) => {
            ret = fmt("volt_{}", S(complex_name(e)));
            orig_ret = fmt("{} _Complex", S(e));
            body = fmt3("{} _Complex volt_r = {}; {} volt_o; volt_o.re = __real__ volt_r; volt_o.im = __imag__ volt_r; return volt_o;", S(e), copy call, copy ret);
        },
        default => {
            ret = this.c_text(&f.ret, c_names) ?? return null;
            orig_ret = copy ret;
        },
    }
    var out = S("");
    if (!f.stat) {
        // the symbol, with the platform's prefix (Mach-O's _)
        out.append("#ifndef VOLT_CW_SYM\n#define VOLT_CW_STR2(x) #x\n#define VOLT_CW_STR(x) VOLT_CW_STR2(x)\n#define VOLT_CW_SYM(n) __asm__(VOLT_CW_STR(__USER_LABEL_PREFIX__) n)\n#endif\n");
        var sym = fmt("VOLT_CW_SYM(\"{}\")", S(f.name));
        val label = f.label;
        if (label) {
            sym = fmt("__asm__(\"{}\")", S(label));
        }
        out.append(fmt4("extern {} {}({}) {};\n", move orig_ret, copy callee, move orig, move sym).as_str());
    }
    out.append(fmt4("static __inline__ {} volt_cw_{}({}) {{ {} }}", move ret, S(f.name), move params, move body).as_str());
    return out;
}

// a static C function `volt_cv_NAME` taking fn f's parameters but its last, a va_list, then C's
// ...: it calls f with the varargs as that va_list. f is called through a declaration of its own
// (as wrapper's is). None when f has no parameter before the va_list (va_start needs one before
// C23) or a type can't be written
attach fn va_wrapper(this: cmapper&, f: cfn&, c_names: std::map<str, str>&) -> std::string? {
    if (f.params.len < 2) {
        return null;
    }
    var params = S("");
    var args = S("");
    var orig = S("");
    for (i) in 0..f.params.len - 1 {
        val t = this.c_text(&f.params.at(i).ty, c_names) ?? return null;
        var a = S("volt_a");
        a.append_uint(@cast<u64>(i));
        params.append(fmt2("{} {}, ", copy t, copy a).as_str());
        if (spelled_ptr(&f.params.at(i).ty)) {
            args.append("(void *)");
        }
        args.append(fmt("{}, ", copy a).as_str());
        orig.append(fmt("{}, ", copy t).as_str());
    }
    params.append("...");
    args.append("volt_ap");
    orig.append("va_list");
    var callee = S(f.name);
    if (!f.stat) {
        callee = fmt("volt_cr_{}", S(f.name));
    }
    val ret = this.c_text(&f.ret, c_names) ?? return null;
    var call = fmt2("{}({})", copy callee, move args);
    var body = fmt("va_list volt_ap; va_start(volt_ap, volt_a{}); ", unum(@cast<u64>(f.params.len - 2)));
    if (ret.as_str() == "void") {
        body.append(fmt("{}; va_end(volt_ap);", move call).as_str());
    } else {
        if (spelled_ptr(&f.ret)) {
            call = fmt("(void *){}", move call);
        }
        body.append(fmt2("{} volt_r = {}; va_end(volt_ap); return volt_r;", copy ret, move call).as_str());
    }
    var out = S("#include <stdarg.h>\n");
    if (!f.stat) {
        out.append("#ifndef VOLT_CW_SYM\n#define VOLT_CW_STR2(x) #x\n#define VOLT_CW_STR(x) VOLT_CW_STR2(x)\n#define VOLT_CW_SYM(n) __asm__(VOLT_CW_STR(__USER_LABEL_PREFIX__) n)\n#endif\n");
        var sym = fmt("VOLT_CW_SYM(\"{}\")", S(f.name));
        val label = f.label;
        if (label) {
            sym = fmt("__asm__(\"{}\")", S(label));
        }
        out.append(fmt4("extern {} {}({}) {};\n", copy ret, copy callee, move orig, move sym).as_str());
    }
    out.append(fmt4("static {} volt_cv_{}({}) {{ {} }}", copy ret, S(f.name), move params, move body).as_str());
    return out;
}

// complex struct n (cf32, cf64) as C's typedef for it, and as the Volt struct bound to it (c_name)
fn complex_c(n: str) -> std::string {
    var e = "double";
    if (n == "cf32") {
        e = "float";
    }
    return fmt2("typedef struct {{ {} re, im; }} volt_{};", S(e), S(n));
}

attach fn complex_item(this: cmapper&, n: str, c_name: str) -> item {
    var re = "f64";
    if (n == "cf32") {
        re = "f32";
    }
    var fields: std::vec<field> = {};
    put(&fields, { name: "re", ty: this.path_ty(re), fallback: null, vis: vis::PUBLIC, span: this.span });
    put(&fields, { name: "im", ty: this.path_ty(re), fallback: null, vis: vis::PUBLIC, span: this.span });
    return this.citem(item_kind::STRUCT({ name: this.complex_volt(n), spec: null, fields: move fields, is_extern: true, is_comptime: false, c_name: c_name }));
}

// a public item at the import's span
attach fn citem(this: cmapper&, k: item_kind) -> item {
    return { kind: move k, span: this.span, attrs: {}, vis: vis::PUBLIC, generics: {} };
}

// what a header import yields: the Volt items, and the #include lines the generated C needs
struct c_imported {
    items: std::vec<item> = {};
    includes: std::vec<std::string> = {};
    statics: std::vec<str> = {}; // the static functions (defined by the headers)
    // what's called per use (cuse.volt): function-like macros and varargs functions needing a
    // wrapper, and what mapping a probed type takes (the declarations, the names given)
    per_use: std::vec<str> = {};
    ctx: usize? = null; // their c_ctx
    names: std::map<str, str> = {};
    c_names: std::map<str, str> = {};
    enum_names: std::map<str, str> = {};
    enum_ints: std::map<str, str> = {};
    complex: std::vec<str> = {};
    cf32: str = "cf32";
    cf64: str = "cf64";
}

// the C compiler as a command: $CC split at whitespace (CC="ccache gcc"), else cc. Pushes the words
// onto argv; returns $CC's text for messages. ponytail: no quoting, so a compiler path with spaces
// needs a wrapper script
fn c_command(argv: std::vec<str>&) -> str {
    return command_from(argv, "CC", "cc");
}

// the C++ compiler, the same way from $CXX (c++)
fn cxx_command(argv: std::vec<str>&) -> str {
    return command_from(argv, "CXX", "c++");
}

fn command_from(argv: std::vec<str>&, var_name: str, dflt: str) -> str {
    var text = std::process::env(var_name) ?? dflt;
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
        text = dflt;
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
    put(&args, this.intern(fmt("-std={}", S(this.c_import_std))));
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
    val std_flag = fmt("-std={}", S(this.c_import_std));
    val rest: str[6] = { "-E", extra, std_flag.as_str(), "-x", "c", "-" };
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
    if (res.per_use.len > 0) {
        // what its per-use calls map types with (import_c says where it is: c_per_use)
        put(&this.c_ctxs, { ns: 0, src: move src, standard: this.c_import_std, keep: false, kept: 0, d: move d, names: copy res.names, c_names: copy res.c_names, enum_names: copy res.enum_names, enum_ints: copy res.enum_ints, complex: copy res.complex, cf32: res.cf32, cf64: res.cf64 });
        res.ctx = this.c_ctxs.len - 1;
    }
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
        var p: cparser = { t: all[i..end], i: 0, d: d, body: end < toks.len && is_p(toks.at(end), "{") };
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
            if (n > 0 && rest[0] != '_') {
                put(&d.fn_macros, rest[0..n]);
            }
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
    // a named enum (by its first typedef, else its tag) is a Volt enum of C's values and integer
    // type, each enumerator a constant of it (one repeating a value names the first one's variant);
    // an anonymous one's stay integer constants
    for (e&) in d.enums.items() {
        var lo: i128 = 0;
        var hi: i128 = 0;
        for (x&) in e.values.items() {
            if (*x < lo) {
                lo = *x;
            }
            if (*x > hi) {
                hi = *x;
            }
        }
        var int: str = "i32";
        if (lo < -2147483648 || hi > 2147483647) {
            if (lo >= 0 && hi <= 4294967295) {
                int = "u32";
            } else if (hi <= 9223372036854775807) {
                int = "i64";
            } else {
                int = "u64";
            }
        }
        m.enum_ints.put(e.tag, int);
        // (by its tag when the typedef is reserved and the tag isn't, as a struct is)
        var name = e.tag;
        val anon = e.tag[0] == '#';
        val td = d.enum_typedef_of.get(e.tag);
        if (td) {
            if (anon || !starts_with(*td, "__")) {
                name = *td;
            }
        } else if (anon) {
            continue;
        }
        if (e.names.len == 0 || starts_with(name, "__") || taken.get(name) != null) {
            continue;
        }
        taken.put(name, true);
        m.enum_names.put(e.tag, name);
        var variants: std::vec<variant> = {};
        var firsts: std::vec<str> = {};
        for (i) in 0..e.names.len {
            var first = *e.names.at(i);
            var dup = false;
            for (k) in 0..i {
                if (!dup && *e.values.at(k) == *e.values.at(i)) {
                    first = *e.names.at(k);
                    dup = true;
                }
            }
            if (!dup) {
                put(&variants, { name: first, payload: null, value: c_int_expr(*e.values.at(i), span), span: span });
            }
            put(&firsts, first);
        }
        put(&res.items, m.citem(item_kind::ENUM({ name: name, backing: m.path_ty(int), variants: move variants, is_error: false, c_enum: true })));
        for (i) in 0..e.names.len {
            var segs: std::vec<path_seg> = {};
            put(&segs, { name: name, args: null });
            put(&segs, { name: *firsts.at(i), args: null });
            var init: expr = { kind: expr_kind::PATH({ segs: move segs, span: span }), span: span };
            val pt: pat = { kind: pat_kind::BIND(*e.names.at(i)), span: span };
            put(&res.items, m.citem(item_kind::GLOBAL({ mutable: false, is_comptime: false, is_static: false, pat: pt, ty: m.path_ty(name), init: move init, span: span, c_name: null })));
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
    // the complex structs' names (past a header's own cf64)
    m.cf32 = this.untaken(&taken, "cf32");
    m.cf64 = this.untaken(&taken, "cf64");
    // functions (the first declaration wins); one with a param or return type Volt can't use is
    // skipped. One taking or giving a long double or a _Complex is called through a wrapper (C
    // converts them: the ABI is the C compiler's), unless it's varargs
    var seen_fns: std::map<str, bool> = {};
    var wraps: std::vec<std::string> = {};
    for (f&) in d.fns.items() {
        if (seen_fns.get(f.name) != null) {
            continue;
        }
        seen_fns.put(f.name, true);
        if (f.stat) {
            put(&res.statics, f.name);
        }
        var wrap = m.needs_wrap(&f.ret);
        for (p&) in f.params.items() {
            wrap = wrap || m.needs_wrap(&p.ty);
        }
        if (wrap && f.variadic) {
            put(&res.per_use, f.name); // a wrapper per call's argument types
            continue;
        }
        // a va_list last: called with varargs, through a variadic wrapper that makes the va_list
        var va = false;
        if (f.params.len > 0 && !f.variadic && !wrap) {
            match (*(m.resolve(&f.params.at(f.params.len - 1).ty, 0) ?? continue)) {
                .VA_LIST => { va = true; },
                default => {},
            }
        }
        var np = f.params.len;
        if (va) {
            np -= 1;
        }
        var params: std::vec<param> = {};
        var ok = true;
        for (i) in 0..np {
            val p = f.params.at(i);
            val t = m.wrap_ty(&p.ty);
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
        val ret = m.wrap_ty(&f.ret) ?? continue;
        var c_name: str? = null;
        if (va) {
            val w = m.va_wrapper(f, &c_names) ?? continue;
            put(&wraps, move w);
            val cn = this.intern(fmt("volt_cv_{}", S(f.name)));
            put(&res.statics, cn);
            c_name = cn;
        }
        if (wrap) {
            val w = m.wrapper(f, &c_names) ?? continue;
            put(&wraps, move w);
            val cn = this.intern(fmt("volt_cw_{}", S(f.name)));
            put(&res.statics, cn);
            c_name = cn;
        }
        put(&res.items, m.citem(item_kind::FN({ name: f.name, spec: null, params: move params, c_varargs: f.variadic || va, ret: move ret, body: null, is_async: false, is_comptime: false, extern_abi: C_HEADER, is_export: false, is_attach: false, c_name: c_name })));
    }
    // function-like macros no function or type has the name of
    for (n) in d.fn_macros.items() {
        if (seen_fns.get(n) != null || taken.get(n) != null) {
            continue;
        }
        seen_fns.put(n, true);
        put(&res.per_use, n);
    }
    // the complex structs the wrappers take and give (C's layout of a complex), then the wrappers
    for (n&) in m.complex.items() {
        put(&res.includes, complex_c(*n));
        put(&res.items, m.complex_item(*n, this.intern(fmt("volt_{}", S(*n)))));
    }
    for (w&) in wraps.items() {
        put(&res.includes, copy *w);
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
        if (starts_with(k.name, "__") || m.enum_names.get(k.in_enum ?? "") != null) {
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
    // what a call made per use maps its types with
    res.names = copy m.names;
    res.c_names = move c_names;
    res.enum_names = copy m.enum_names;
    res.enum_ints = copy m.enum_ints;
    res.complex = copy m.complex;
    res.cf32 = m.cf32;
    res.cf64 = m.cf64;
}

// base, with _ added while a header's type has the name (a header's own cf64)
attach fn untaken(this: checker&, taken: std::map<str, bool>&, base: str) -> str {
    var n = S(base);
    while (taken.get(n.as_str()) != null) {
        n.push('_');
    }
    return this.intern(move n);
}

// x as a Volt integer literal (a negative one is -literal)
fn c_int_expr(x: i128, span: span) -> expr {
    if (x < 0) {
        var lit: expr = { kind: expr_kind::INT(@cast<u128>(-x)), span: span };
        return { kind: expr_kind::UNARY(unop::NEG, bx(move lit)), span: span };
    }
    return { kind: expr_kind::INT(@cast<u128>(x)), span: span };
}

// the newest C standard both libclang and the C compiler take, in GNU's form (POSIX's names stay
// in the headers): a C import's, unless its @standard or the program's --cc -std=... says otherwise
var c_newest_found: str = "";

attach fn c_newest(this: checker&) -> str {
    if (this.opts.c_std.len > 0) {
        return this.opts.c_std;
    }
    if (c_newest_found.len == 0) {
        c_newest_found = "gnu99";
        val all: str[3] = { "gnu23", "gnu17", "gnu11" };
        for (s) in all {
            var flag = S("-std=");
            flag.append(s);
            var args: std::vec<str> = {};
            put(&args, "-x");
            put(&args, "c");
            put(&args, flag.as_str());
            val tu = clang_parse("volt_c_std.c", "", &args);
            if (tu.tu == null || tu.first_error() != null) {
                continue;
            }
            var argv: std::vec<str> = {};
            c_command(&argv);
            val rest: str[5] = { flag.as_str(), "-x", "c", "-fsyntax-only", "-" };
            for (a) in rest {
                put(&argv, a);
            }
            val r = std::process::capture(argv.items(), "") catch |e| {
                c_newest_found = s; // no C compiler (an editor): libclang's says
                break;
            };
            if (r.code == 0) {
                c_newest_found = s;
                break;
            }
        }
    }
    return c_newest_found;
}

// the standard Volt's own C is compiled under: the GNU form of the C imports' default (it
// includes their headers; the runtime needs POSIX's names), C99 at the least (what Volt's C needs)
attach fn c_own_std(this: checker&) -> str {
    val s = c_gnu(this.c_newest());
    if (s == "gnu89" || s == "gnu90") {
        return "gnu99";
    }
    return s;
}

// a C standard's GNU form (c11: gnu11), which shares Volt's own C unit with it
fn c_gnu(s: str) -> str {
    val iso: str[7] = { "iso9899:1990", "iso9899:199409", "iso9899:1999", "iso9899:2011", "iso9899:2017", "iso9899:2018", "iso9899:2024" };
    val gnu: str[7] = { "gnu90", "gnu90", "gnu99", "gnu11", "gnu17", "gnu17", "gnu23" };
    for (i) in 0..7 {
        if (s == iso[i]) {
            return gnu[i];
        }
    }
    if (s.len > 1 && s[0] == 'c' && s[1] != '+') {
        if (s == "c99") { return "gnu99"; }
        if (s == "c89") { return "gnu89"; }
        if (s == "c90") { return "gnu90"; }
        if (s == "c11") { return "gnu11"; }
        if (s == "c17") { return "gnu17"; }
        if (s == "c18") { return "gnu17"; }
        if (s == "c23") { return "gnu23"; }
        if (s == "c2x") { return "gnu2x"; }
        if (s == "c2y") { return "gnu2y"; }
    }
    return s;
}

// the C unit for standard s (one per standard other than Volt's own C's)
attach fn c_unit_for(this: checker&, s: str) -> u32 {
    for (i) in 0..this.c_units.len {
        if (*this.c_units.at(i) == s) {
            return @cast<u32>(i);
        }
    }
    put(&this.c_units, s);
    var head = fmt2("/* generated by voltc: C headers compiled under -std={}, which Volt's own C (-std={}) can't\n   include; Volt calls their functions through these pointers */\n", S(s), S(this.c_own_std()));
    head.append("#include <stdio.h>\n#include <stdlib.h>\n\n/* a function the headers declare and nothing defines (its library isn't linked), when called */\nstatic void volt_c_missing(const char *name) {\n    fprintf(stderr, \"panic: the C function %s isn't defined anywhere (is its library linked?)\\n\", name);\n    exit(101);\n}\n\n");
    put(&this.c_unit_text, move head);
    put(&this.c_unit_weak, {});
    return @cast<u32>(this.c_units.len - 1);
}

// an item of an import kept out of Volt's C (unit u): a function is reached through a pointer the
// unit defines (weak for one the headers only declare: one nothing defines panics when called, as
// the unit's constructor points it at a stub), a global by its symbol, and a struct is laid out
// by Volt
attach fn keep_out(this: checker&, it: item&, imp: c_imported&, u: u32, span: span) -> compile_error!void {
    var name: str = "";
    match (it.kind) {
        .FN(f&) => { name = f.c_name ?? f.name; },
        .GLOBAL(l&) => {
            this.c_kept.put(l.c_name ?? return, u);
            return;
        },
        .STRUCT(sd&) => {
            if (sd.c_partial || sd.c_union || sd.c_offsets != null) {
                return fail(span, fmt2("the C struct {} shares or hides its fields' bytes (a union, a bitfield), and its header's standard ({}) isn't Volt's own C's: only that standard's C can lay it out; import it under the program's standard", S(sd.c_name ?? sd.name), S(*this.c_units.at(@cast<usize>(u)))));
            }
            sd.c_name = null;
            return;
        },
        default => { return; },
    }
    if (this.c_kept.get(name) != null) {
        return;
    }
    this.c_kept.put(name, u);
    var stat = false;
    for (x&) in imp.statics.items() {
        if (*x == name) {
            stat = true;
        }
    }
    val text = this.c_unit_text.at(@cast<usize>(u));
    if (!stat) {
        text.append(fmt("#pragma weak {}\n", S(name)).as_str());
    }
    text.append(fmt2("void *volt_c_{} = (void *){};\n", S(name), S(name)).as_str());
    if (!stat) {
        text.append(fmt2("static void volt_c_no_{}(void) {{\n    volt_c_missing(\"{}\");\n}}\n", S(name), S(name)).as_str());
        this.c_unit_weak.at(@cast<usize>(u)).append(fmt3("    if (!volt_c_{}) {{\n        volt_c_{} = (void *)volt_c_no_{};\n    }}\n", S(name), S(name), S(name)).as_str());
    }
}

// `use { "a.h", "b.h" } as alias;`: the headers' declarations as namespace alias
attach fn import_c(this: checker&, headers: std::vec<std::string>&, alias: str, ns: u32, standard: str, span: span) -> compile_error!void {
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
    // read under its standard; one other than Volt's own C's is kept out of Volt's C, in a unit
    // of its own standard that Volt calls through pointers
    var std_name = standard;
    if (std_name.len == 0) {
        std_name = this.c_newest();
        if (dir == null) {
            std_name = this.c_own_std(); // std's own: always in Volt's C
        }
    }
    this.c_import_std = std_name;
    val imp = try this.import_headers(headers, dir, span);
    val keep = c_gnu(std_name) != this.c_own_std();
    var kept: u32 = 0;
    if (keep) {
        kept = this.c_unit_for(std_name);
    }
    for (inc&) in imp.includes.items() {
        if (keep) {
            val text = this.c_unit_text.at(@cast<usize>(kept));
            var line = copy *inc;
            line.push('\n');
            if (!contains(text.as_str(), line.as_str())) {
                text.append(line.as_str());
            }
            continue;
        }
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
            .ENUM(e) => {
                kind = 4;
                key_name = e.name;
                name = e.name;
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
            var mine = copy *it;
            if (keep) {
                try this.keep_out(&mine, &imp, kept, span);
            }
            put(&this.owned_items, bx(move mine));
            val kept = this.owned_items.at(this.owned_items.len - 1);
            this.importing_c = true;
            val r = this.collect_item(*kept, n, null);
            this.importing_c = false;
            try r;
        }
    }
    try this.c_per_use(&imp, n, keep, kept, span);
}
