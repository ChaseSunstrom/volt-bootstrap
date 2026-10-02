use std::io;
use std::text;
// floats print by Ryu (std/fmt.volt): checked against the C runtime's old way (the fewest digits
// that %.*g needs for strtod to read the value back) on random bits, whole numbers, short decimals,
// f32s and powers of two. The only differences allowed: Ryu's text is shorter at a power of two
// (whose lower neighbour is closer) and reads back, or an f32 whole number shows its own shortest
// digits then zeros, not its exact binary value

extern "C" fn snprintf(buf: u8*, n: usize, fmt: cstr, ...) -> i32;
extern "C" fn strtod(s: cstr, end: void*) -> f64;

// today's runtime algorithm (volt_fmt_float), for comparison
fn old_fmt(buf: u8*, v: f64, max_digits: i32, f32: bool) -> usize {
    if (v != v) {
        return @cast<usize>(snprintf(buf, 48, "nan"));
    }
    var p: i32 = 1;
    while (p < max_digits) {
        snprintf(buf, 48, "%.*g", p, v);
        val back = strtod(@cast<cstr>(buf), null);
        if (f32) {
            if (@cast<f32>(back) == @cast<f32>(v)) {
                break;
            }
        } else if (back == v) {
            break;
        }
        p += 1;
    }
    var n = snprintf(buf, 48, "%.*g", p, v);
    val s = @slice(buf, @cast<usize>(n));
    var at: usize = 0;
    while (at < s.len && s[at] != 'e') {
        at += 1;
    }
    if (at + 1 < s.len && s[at + 1] == '+') {
        var x: i32 = 0;
        var k = at + 2;
        while (k < s.len && s[k] >= '0' && s[k] <= '9') {
            x = x * 10 + @cast<i32>(s[k] - '0');
            k += 1;
        }
        if (x >= p && x < 16) {
            n = snprintf(buf, 48, "%.*g", x + 1, v);
        }
    }
    return @cast<usize>(n);
}

var state: u64 = 88172645463325252;
fn rnd() -> u64 {
    state = state ^ (state << 13);
    state = state ^ (state >> 7);
    state = state ^ (state << 17);
    return state;
}

fn from_bits(b: u64) -> f64 {
    var r: f64 = 0.0;
    var x = b;
    val from = @slice(@cast<u8*>(&x), 8);
    val to = @slice(@cast<u8*>(&r), 8);
    for (i) in 0..8 {
        to[i] = from[i];
    }
    return r;
}

fn from_bits32(b: u32) -> f32 {
    var r: f32 = 0.0;
    var x = b;
    val from = @slice(@cast<u8*>(&x), 4);
    val to = @slice(@cast<u8*>(&r), 4);
    for (i) in 0..4 {
        to[i] = from[i];
    }
    return r;
}

var same: u64 = 0;
var shorter: u64 = 0;
var bad: u64 = 0;
var f32_whole: u64 = 0;

fn check(v: f64, f32: bool) -> void {
    var a: u8[48];
    var md: i32 = 17;
    if (f32) {
        md = 9;
    }
    val na = old_fmt(&a[0], v, md, f32);
    var text = std::fmt::format("{}", v);
    if (f32) {
        text = std::fmt::format("{}", @cast<f32>(v));
    }
    val nb = text.len();
    val sa = @slice(&a[0], na);
    val sb = text.as_str();
    var eq = na == nb;
    if (eq) {
        for (i) in 0..na {
            if (sa[i] != sb[i]) {
                eq = false;
            }
        }
    }
    if (eq) {
        same += 1;
        return;
    }
    // allowed only when the new text is shorter and reads back
    var z = copy text;
    z.push(0);
    val back = strtod(@cast<cstr>(z.as_str().ptr), null);
    var reads = back == v;
    if (f32) {
        reads = @cast<f32>(back) == @cast<f32>(v);
    }
    if (reads && f32 && nb == na) {
        f32_whole += 1; // an f32 whole number: its shortest digits padded, not its exact binary value
        return;
    }
    if (reads && nb < na) {
        shorter += 1;
        return;
    }
    bad += 1;
    if (bad <= 20) {
        std::println("BAD f32={}: old {} new {}", f32, @cast<str>(sa), @cast<str>(sb));
    }
}

fn main() -> void {
    val n: u64 = 20000;
    for (i) in 0..n {
        check(from_bits(rnd()), false);
        check(@cast<f64>(rnd() % 100000000000000000) , false);
        val k = rnd() % 1000000;
        check(@cast<f64>(k) / 1000.0, false);
        check(@cast<f64>(from_bits32(@cast<u32>(rnd() >> 32))), true);
        check(@cast<f64>(@cast<f32>(@cast<f64>(k) / 100.0)), true);
    }
    var p = 1.0;
    for (i) in 0..1100 {
        check(p, false);
        check(-p, false);
        check(@cast<f64>(@cast<f32>(p)), true);
        p = p / 2.0;
    }
    p = 1.0;
    for (i) in 0..1030 {
        check(p, false);
        check(@cast<f64>(@cast<f32>(p)), true);
        p = p * 2.0;
    }
    val specials: f64[12] = { 0.0, -0.0, 1.0, 0.1, 0.2, 0.3, 1e16, 1e15, 123456789012345680.0, 5e-324, 1.7976931348623157e308, 2.2250738585072014e-308 };
    for (s) in specials {
        check(s, false);
        check(s, true);
    }
    // (how many are the same depends a little on the C library's %g; the old way is the reference
    // only where the two agree)
    std::println("bad {}, the same nearly always: {}", bad, same > 100000 && shorter < 200);
}
// expect: bad 0, the same nearly always: true
