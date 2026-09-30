// Source text to tokens: a port of bootstrap/lexer.rs (same tokens, spans and
// messages, so the two can be compared).

// a byte range [lo, hi) in source file `file` (an index into the loaded files)
struct span {
    file: u32 = 0;
    lo: u32 = 0;
    hi: u32 = 0;
}

// the smallest span covering both; keeps this's file, so both must come from the same file
attach fn to(this: span&, other: span) -> span {
    var lo = this.lo;
    if (other.lo < lo) {
        lo = other.lo;
    }
    var hi = this.hi;
    if (other.hi > hi) {
        hi = other.hi;
    }
    return { file: this.file, lo: lo, hi: hi };
}

// a secondary span in a diagnostic, underlined with its own text (like "declared here")
struct label {
    span: span;
    msg: std::string;
}

// an error (or warning) at a place in the source, with labelled secondary spans and `help: ...`
// lines; diag.volt renders it
struct diag {
    span: span;
    msg: std::string;
    warning: bool = false;
    labels: std::vec<label> = {};
    notes: std::vec<std::string> = {};
    diff: bool = false; // a type mismatch (expected A, found B): colour shows where A and B differ
}

// the error every compiler phase returns: parsing stops at the first, checking at the first in each
// function
error compile_error {
    AT: diag,
}

// a compile_error at src[lo..hi] of file
fn fail(lo: usize, hi: usize, file: u32, msg: str) -> compile_error {
    return compile_error::AT({ span: { file: file, lo: @cast<u32>(lo), hi: @cast<u32>(hi) }, msg: std::string::from(msg) });
}

// a token's kind and value. INT holds the digits' value only (`-` is a separate PUNCT), STR the bytes after
// escapes, CHAR a code point, PUNCT one of PUNCTS; IDENT and BUILTIN point into the source text
enum tok {
    IDENT: str,
    INT: u128,
    FLOAT: f64,
    CHAR: u32,
    STR: std::string,
    BUILTIN: str, // @name
    PUNCT: str,
    EOF,
}

struct token {
    tok: tok;
    span: span;
    glued: bool; // no whitespace between this token and the previous one
}

// longest first. ">>" and ">>=" are left out on purpose: the parser joins glued '>' tokens,
// so `box<box<T>>` closes two generic lists
val PUNCTS: str[] = {
    "...", "..=", "<<=", "+%=", "-%=", "*%=", "::", "->", "=>", "..", "==", "!=", "<=", ">=", "&&", "||", "<<",
    "+=", "-=", "*=", "/=", "%=", "&=", "|=", "^=", "++", "--", "+%", "-%", "*%", "??", "(", ")", "{", "}", "[",
    "]", "<", ">", ",", ";", ":", ".", "=", "+", "-", "*", "/", "%", "&", "|", "^", "~", "!", "?",
};

fn is_space(c: u8) -> bool {
    return c == ' ' || c == '\t' || c == '\n' || c == '\r' || c == 11 || c == 12;
}
fn is_digit(c: u8) -> bool {
    return c >= '0' && c <= '9';
}
fn is_alpha(c: u8) -> bool {
    return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z');
}
fn is_alnum(c: u8) -> bool {
    return is_alpha(c) || is_digit(c);
}
fn starts_with(s: str, p: str) -> bool {
    return s.len >= p.len && s[0..p.len] == p;
}

// the UTF-8 character starting at s[i]: its bytes and code point
fn utf8_at(s: str, i: usize) -> (len: usize, cp: u32) {
    val c = s[i];
    var n: usize = 1;
    var cp = @cast<u32>(c);
    if (c >= 0xf0) {
        n = 4;
        cp = @cast<u32>(c & 7);
    } else if (c >= 0xe0) {
        n = 3;
        cp = @cast<u32>(c & 15);
    } else if (c >= 0xc0) {
        n = 2;
        cp = @cast<u32>(c & 31);
    }
    if (i + n > s.len) {
        return (1, @cast<u32>(c));
    }
    var k: usize = 1;
    while (k < n) {
        cp = (cp << 6) | @cast<u32>(s[i + k] & 63);
        k++;
    }
    return (n, cp);
}

// tokenizes a whole file; the result always ends with EOF. Fails at the first bad character or literal
fn lex(src: str, file: u32) -> compile_error!std::vec<token> {
    var out: std::vec<token> = {};
    var i: usize = 0;
    var glued = false;
    while (i < src.len) {
        val c = src[i];
        if (is_space(c)) {
            i++;
            glued = false;
            continue;
        }
        if (c == '/' && i + 1 < src.len && src[i + 1] == '/') {
            while (i < src.len && src[i] != '\n') {
                i++;
            }
            glued = false;
            continue;
        }
        if (c == '/' && i + 1 < src.len && src[i + 1] == '*') {
            val start = i;
            i += 2;
            while (i + 1 < src.len && !(src[i] == '*' && src[i + 1] == '/')) {
                i++;
            }
            if (i + 1 >= src.len) {
                return fail(start, start + 2, file, "unterminated block comment");
            }
            i += 2;
            glued = false;
            continue;
        }
        // one token; its kind is decided by the first byte
        val start = i;
        var t: tok = tok::EOF;
        if (is_alpha(c) || c == '_') {
            while (i < src.len && (is_alnum(src[i]) || src[i] == '_')) {
                i++;
            }
            t = tok::IDENT(src[start..i]);
        } else if (c == '@') {
            i++;
            while (i < src.len && (is_alnum(src[i]) || src[i] == '_')) {
                i++;
            }
            if (i == start + 1) {
                return fail(start, i, file, "expected a builtin name after @");
            }
            t = tok::BUILTIN(src[start + 1..i]);
        } else if (is_digit(c)) {
            // after '.', only integers (t.0.1 is two tuple indexes, not a float)
            var after_dot = false;
            if (out.len > 0) {
                match (out.at(out.len - 1).tok) {
                    .PUNCT(p) => { after_dot = p == "."; },
                    default => {},
                }
            }
            t = try lex_number(src, &i, after_dot, start, file);
        } else if (c == '"') {
            i++;
            var s: std::string = {};
            loop {
                if (i >= src.len || src[i] == '\n') {
                    return fail(start, i, file, "unterminated string");
                }
                if (src[i] == '"') {
                    i++;
                    break;
                }
                if (src[i] == '\\') {
                    try escape(src, &i, file, &s);
                } else {
                    s.push(src[i]);
                    i++;
                }
            }
            t = tok::STR(move s);
        } else if (c == '\'') {
            i++;
            if (i >= src.len) {
                return fail(start, i, file, "unterminated char literal");
            }
            var v: u32 = 0;
            if (src[i] == '\\') {
                var bytes: std::string = {};
                try escape(src, &i, file, &bytes);
                val b = bytes.as_str();
                v = utf8_at(b, 0).cp;
            } else {
                val ch = utf8_at(src, i);
                i += ch.len;
                v = ch.cp;
            }
            if (i >= src.len || src[i] != '\'') {
                return fail(start, i, file, "expected ' to close char literal");
            }
            i++;
            t = tok::CHAR(v);
        } else {
            val rest = src[i..src.len];
            var found = false;
            for (p) in PUNCTS {
                if (starts_with(rest, p)) {
                    i += p.len;
                    t = tok::PUNCT(p);
                    found = true;
                    break;
                }
            }
            if (!found) {
                var msg = std::string::from("unexpected character '");
                msg.append(rest[0..utf8_at(rest, 0).len]);
                msg.append("'");
                return fail(i, i + 1, file, msg.as_str());
            }
        }
        out.push({ tok: move t, span: { file: file, lo: @cast<u32>(start), hi: @cast<u32>(i) }, glued: glued }) catch @panic("out of memory");
        glued = true;
    }
    out.push({ tok: tok::EOF, span: { file: file, lo: @cast<u32>(src.len), hi: @cast<u32>(src.len) }, glued: false }) catch @panic("out of memory");
    return move out;
}

// the value of a digit in any radix up to 36; 99 for a non-digit
fn digit_value(c: u8) -> u32 {
    if (is_digit(c)) {
        return @cast<u32>(c - '0');
    }
    if (c >= 'a' && c <= 'z') {
        return @cast<u32>(c - 'a') + 10;
    }
    if (c >= 'A' && c <= 'Z') {
        return @cast<u32>(c - 'A') + 10;
    }
    return 99;
}

extern "C" fn strtod(s: cstr, end: void*) -> f64;

// reads an int or float literal at src[*ip] and moves *ip past it. Takes 0x/0b/0o prefixes and drops `_`;
// with int_only (right after a `.`) it never reads a fraction or exponent. start is where the literal
// began, for the error span
fn lex_number(src: str, ip: usize&, int_only: bool, start: usize, file: u32) -> compile_error!tok {
    var i = *ip;
    var radix: u32 = 10;
    if (src[i] == '0' && i + 1 < src.len && (src[i + 1] == 'x' || src[i + 1] == 'b' || src[i + 1] == 'o')) {
        if (src[i + 1] == 'x') {
            radix = 16;
        } else if (src[i + 1] == 'b') {
            radix = 2;
        } else {
            radix = 8;
        }
        i += 2;
    }
    val digits_start = i;
    while (i < src.len && (is_alnum(src[i]) || src[i] == '_')) {
        // a decimal literal stops at `e` so the exponent is read below; other letters are kept and fail the
        // digit parse
        if (radix == 10 && (src[i] == 'e' || src[i] == 'E')) {
            break;
        }
        i++;
    }
    var is_float = false;
    if (radix == 10 && !int_only) {
        if (i + 1 < src.len && src[i] == '.' && is_digit(src[i + 1])) {
            is_float = true;
            i++;
            while (i < src.len && (is_digit(src[i]) || src[i] == '_')) {
                i++;
            }
        }
        if (i < src.len && (src[i] == 'e' || src[i] == 'E')) {
            var j = i + 1;
            if (j < src.len && (src[j] == '+' || src[j] == '-')) {
                j++;
            }
            if (j < src.len && is_digit(src[j])) {
                is_float = true;
                i = j;
                while (i < src.len && is_digit(src[i])) {
                    i++;
                }
            }
        }
    }
    *ip = i;
    // the digits without _
    var text: std::string = {};
    for (c) in src[digits_start..i] {
        if (c != '_') {
            text.push(c);
        }
    }
    if (is_float) {
        var full: std::string = {};
        for (c) in src[start..i] {
            if (c != '_') {
                full.push(c);
            }
        }
        return tok::FLOAT(strtod(full.c_str(), null));
    }
    var v: u128 = 0;
    var ok = text.len() > 0;
    val max: u128 = ~@cast<u128>(0); // ponytail: literals above i128::MAX don't check yet
    for (c) in text.as_str() {
        val d = digit_value(c);
        if (d >= radix || v > (max - @cast<u128>(d)) / @cast<u128>(radix)) {
            ok = false;
            break;
        }
        v = v * @cast<u128>(radix) + @cast<u128>(d);
    }
    if (!ok) {
        var msg = std::string::from("bad number literal '");
        msg.append(text.as_str());
        msg.append("'");
        return fail(start, i, file, msg.as_str());
    }
    return tok::INT(v);
}

// decodes the backslash escape at src[*ip] and moves *ip past it; its bytes (`\u{...}` as UTF-8) go into out
fn escape(src: str, ip: usize&, file: u32, out: std::string&) -> compile_error!void {
    var i = *ip + 1; // backslash
    if (i >= src.len) {
        return fail(i, i + 1, file, "unterminated escape");
    }
    val c = src[i];
    i++;
    *ip = i;
    if (c == 'n') {
        out.push('\n');
    } else if (c == 't') {
        out.push('\t');
    } else if (c == 'r') {
        out.push('\r');
    } else if (c == '0') {
        out.push(0);
    } else if (c == '\\' || c == '"' || c == '\'') {
        out.push(c);
    } else if (c == 'x') {
        if (i + 2 > src.len || digit_value(src[i]) >= 16 || digit_value(src[i + 1]) >= 16) {
            return fail(i, i + 1, file, "bad \\x escape");
        }
        out.push(@cast<u8>(digit_value(src[i]) * 16 + digit_value(src[i + 1])));
        *ip = i + 2;
    } else if (c == 'u') {
        if (i >= src.len || src[i] != '{') {
            return fail(i, i + 1, file, "expected \\u{...}");
        }
        var end = i;
        while (end < src.len && src[end] != '}') {
            end++;
        }
        if (end >= src.len) {
            return fail(i, i + 1, file, "unterminated \\u{");
        }
        var cp: u32 = 0;
        var ok = end > i + 1 && end - i - 1 <= 8;
        for (h) in src[i + 1..end] {
            if (digit_value(h) >= 16) {
                ok = false;
            } else if (ok) {
                cp = cp * 16 + digit_value(h);
            }
        }
        if (!ok || cp > 0x10ffff || (cp >= 0xd800 && cp < 0xe000)) {
            return fail(end + 1, end + 2, file, "bad \\u escape");
        }
        *ip = end + 1;
        push_utf8(out, cp);
    } else {
        var msg = std::string::from("unknown escape \\");
        msg.push(c);
        return fail(i, i + 1, file, msg.as_str());
    }
}

// appends code point cp encoded as UTF-8
fn push_utf8(out: std::string&, cp: u32) -> void {
    if (cp < 0x80) {
        out.push(@cast<u8>(cp));
    } else if (cp < 0x800) {
        out.push(@cast<u8>(0xc0 | (cp >> 6)));
        out.push(@cast<u8>(0x80 | (cp & 63)));
    } else if (cp < 0x10000) {
        out.push(@cast<u8>(0xe0 | (cp >> 12)));
        out.push(@cast<u8>(0x80 | ((cp >> 6) & 63)));
        out.push(@cast<u8>(0x80 | (cp & 63)));
    } else {
        out.push(@cast<u8>(0xf0 | (cp >> 18)));
        out.push(@cast<u8>(0x80 | ((cp >> 12) & 63)));
        out.push(@cast<u8>(0x80 | ((cp >> 6) & 63)));
        out.push(@cast<u8>(0x80 | (cp & 63)));
    }
}
