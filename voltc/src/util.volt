// Small helpers for the checker: messages, errors, sets of ids.
use std::mem;

// an owned copy of s, to build messages from
fn S(s: str) -> std::string {
    return std::string::from(s);
}

// v as decimal text
fn num(v: i128) -> std::string {
    var s: std::string = {};
    if (v < 0) {
        s.push('-');
        append_u128(&s, @cast<u128>(0 -% v));
    } else {
        append_u128(&s, @cast<u128>(v));
    }
    return s;
}

fn unum(v: u64) -> std::string {
    var s: std::string = {};
    s.append_uint(v);
    return s;
}

// f with each {} replaced by the next part
fn fmt(f: str, a: std::string) -> std::string {
    var parts: std::vec<std::string> = {};
    put(&parts, move a);
    return fmt_parts(f, &parts);
}

fn fmt2(f: str, a: std::string, b: std::string) -> std::string {
    var parts: std::vec<std::string> = {};
    put(&parts, move a);
    put(&parts, move b);
    return fmt_parts(f, &parts);
}

fn fmt3(f: str, a: std::string, b: std::string, c: std::string) -> std::string {
    var parts: std::vec<std::string> = {};
    put(&parts, move a);
    put(&parts, move b);
    put(&parts, move c);
    return fmt_parts(f, &parts);
}

fn fmt4(f: str, a: std::string, b: std::string, c: std::string, d: std::string) -> std::string {
    var parts: std::vec<std::string> = {};
    put(&parts, move a);
    put(&parts, move b);
    put(&parts, move c);
    put(&parts, move d);
    return fmt_parts(f, &parts);
}

// fmt's worker: each {} takes the next part (once they run out, {} stays), {{ and }} are braces
fn fmt_parts(f: str, parts: std::vec<std::string>&) -> std::string {
    var out: std::string = {};
    var next: usize = 0;
    var i: usize = 0;
    while (i < f.len) {
        if (f[i] == '{' && i + 1 < f.len && f[i + 1] == '}' && next < parts.len) {
            out.append(parts.at(next).as_str());
            next += 1;
            i += 2;
        } else if ((f[i] == '{' || f[i] == '}') && i + 1 < f.len && f[i + 1] == f[i]) {
            out.push(f[i]); // {{ and }} are literal braces, as in Rust's format!
            i += 2;
        } else {
            out.push(f[i]);
            i += 1;
        }
    }
    return out;
}

// an error at sp (fails: the same with a str message)
fn fail(sp: span, msg: std::string) -> compile_error {
    return compile_error::AT({ span: sp, msg: move msg });
}

fn fails(sp: span, msg: str) -> compile_error {
    return compile_error::AT({ span: sp, msg: S(msg) });
}

// the message of an error
fn err_msg(e: compile_error&) -> str {
    match (*e) {
        .AT(d&) => { return d.msg.as_str(); }, // a view into e (a copied binding would dangle)
    }
}

// the diagnostic inside an error, copied out
fn err_diag(e: compile_error&) -> diag {
    match (*e) {
        .AT(d&) => { return copy *d; },
    }
}

fn contains(s: str, part: str) -> bool {
    if (part.len > s.len) {
        return false;
    }
    for (i) in 0..(s.len - part.len + 1) {
        if (s[i..i + part.len] == part) {
            return true;
        }
    }
    return false;
}

fn ends_with(s: str, p: str) -> bool {
    return s.len >= p.len && s[s.len - p.len..] == p;
}

// a set of ids (small: linear scans)
struct idset {
    ids: std::vec<u32> = {};
}

attach fn has(this: idset&, id: u32) -> bool {
    for (x&) in this.ids.items() {
        if (*x == id) {
            return true;
        }
    }
    return false;
}

// add id; false if it was already there
attach fn add(this: idset&, id: u32) -> bool {
    if (this.has(id)) {
        return false;
    }
    put(&this.ids, id);
    return true;
}

// remove id if it's there (the order isn't kept)
attach fn remove(this: idset&, id: u32) -> void {
    for (i) in 0..this.ids.len {
        if (*this.ids.at(i) == id) {
            *this.ids.at(i) = *this.ids.at(this.ids.len - 1);
            this.ids.pop();
            return;
        }
    }
}

attach fn add_all(this: idset&, other: idset&) -> void {
    for (x&) in other.ids.items() {
        this.add(*x);
    }
}

attach fn copy(this: idset&) -> idset {
    return { ids: copy this.ids };
}

// FNV-1a: small, stable across builds and platforms (symbol names, error codes, guards use it)
fn fnv32(s: str) -> u32 {
    var h: u32 = 0x811c9dc5;
    for (b) in s {
        h = h ^ @cast<u32>(b);
        h = h *% 0x01000193;
    }
    return h;
}

// 8 lowercase hex digits
fn hex8(v: u32) -> std::string {
    var s: std::string = {};
    var shift: u32 = 32;
    while (shift > 0) {
        shift -= 4;
        s.push(hex_digit(@cast<u64>((v >> shift) & 15)));
    }
    return s;
}

// ---------- i128 arithmetic that reports overflow instead of trapping (comptime) ----------

val I128_MAX: i128 = 170141183460469231731687303715884105727;
val I128_MIN: i128 = -170141183460469231731687303715884105727 - 1;

fn add_i128(x: i128, y: i128) -> i128? {
    if ((y > 0 && x > I128_MAX - y) || (y < 0 && x < I128_MIN - y)) {
        return null;
    }
    return x + y;
}

fn sub_i128(x: i128, y: i128) -> i128? {
    if ((y < 0 && x > I128_MAX + y) || (y > 0 && x < I128_MIN + y)) {
        return null;
    }
    return x - y;
}

fn mul_i128(x: i128, y: i128) -> i128? {
    if (x == 0 || y == 0) {
        return 0;
    }
    if ((x == -1 && y == I128_MIN) || (y == -1 && x == I128_MIN)) {
        return null;
    }
    val r = x *% y;
    if (r / y != x) {
        return null;
    }
    return r;
}

fn div_i128(x: i128, y: i128) -> i128? {
    if (y == 0 || (x == I128_MIN && y == -1)) {
        return null;
    }
    return x / y;
}

fn rem_i128(x: i128, y: i128) -> i128? {
    if (y == 0 || (x == I128_MIN && y == -1)) {
        return null;
    }
    return x % y;
}

// shifts check only the amount; bits shifted out are lost
fn shl_i128(x: i128, y: i128) -> i128? {
    if (y < 0 || y >= 128) {
        return null;
    }
    return x << y;
}

fn shr_i128(x: i128, y: i128) -> i128? {
    if (y < 0 || y >= 128) {
        return null;
    }
    return x >> y;
}

// x cut to `bits` bits, sign-extended when signed (two's complement wrapping)
fn wrap_bits(x: i128, bits: u32, signed: bool) -> i128 {
    if (bits >= 128) {
        return x;
    }
    val one: i128 = 1;
    val m = x & ((one << bits) - 1);
    if (signed && m >= (one << (bits - 1))) {
        return m - (one << bits);
    }
    return m;
}
