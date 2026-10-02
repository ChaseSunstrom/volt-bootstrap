use std::io;
// {:spec} formatting (std/fmt.volt) against libc's snprintf on random values: floats with a
// precision as %.Nf and %.Ne (exact digits, ties to even), widths, fills, signs and zero padding,
// and integers in hex and octal. Volt's exponent drops the + and leading zeros (1.5e3), and its
// "nan" never has a sign; the comparison allows for both

extern "C" fn snprintf(buf: u8*, n: usize, fmt: cstr, ...) -> i32;
extern "C" fn strtod(s: cstr, end: void*) -> f64;

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

var checked: u64 = 0;
var bad: u64 = 0;
var buf: u8[1600];

// C's %e text the way Volt writes it: e5, e-4 (no +, no leading zeros)
fn volt_exp(n: usize) -> usize {
    var at: usize = 0;
    while (at < n && buf[at] != 'e' && buf[at] != 'E') {
        at += 1;
    }
    if (at == n) {
        return n;
    }
    var out = at + 1;
    var k = at + 1;
    if (buf[k] == '-') {
        buf[out] = '-';
        out += 1;
        k += 1;
    } else if (buf[k] == '+') {
        k += 1;
    }
    while (k + 1 < n && buf[k] == '0') {
        k += 1;
    }
    while (k < n) {
        buf[out] = buf[k];
        out += 1;
        k += 1;
    }
    return out;
}

// buf's n bytes right-aligned in w columns
fn right(n: usize, w: usize) -> usize {
    if (n >= w) {
        return n;
    }
    val pad = w - n;
    var i = n;
    while (i > 0) {
        i -= 1;
        buf[i + pad] = buf[i];
    }
    for (k) in 0..pad {
        buf[k] = ' ';
    }
    return w;
}

fn compare(what: str, got: std::string, n: usize) -> void {
    checked += 1;
    val want = @cast<str>(@slice(&buf[0], n));
    if (got.as_str() != want) {
        bad += 1;
        if (bad <= 20) {
            std::println("BAD {}: snprintf {} volt {}", what, want, got);
        }
    }
}

// the C runtime's {:e} with no precision: the fewest digits whose %.Ne reads back as v (as an f32
// when f32 is set)
fn shortest_e(v: f64, f32: bool) -> usize {
    var p: i32 = 0;
    while (p < 17) {
        snprintf(&buf[0], 1600, "%.*e", p, v);
        val back = strtod(@cast<cstr>(&buf[0]), null);
        if ((f32 && @cast<f32>(back) == @cast<f32>(v)) || (!f32 && back == v)) {
            break;
        }
        p += 1;
    }
    return volt_exp(@cast<usize>(snprintf(&buf[0], 1600, "%.*e", p, v)));
}

fn floats(v: f64) -> void {
    if (v != v) {
        return; // printf's nan may have a sign
    }
    compare("{:e}", std::fmt::format("{:e}", v), shortest_e(v, false));
    val n = shortest_e(v, false);
    for (i) in 0..n {
        if (buf[i] == 'e') {
            buf[i] = 'E';
        }
    }
    compare("{:E}", std::fmt::format("{:E}", v), n);
    compare("{:e} f32", std::fmt::format("{:e}", @cast<f32>(v)), shortest_e(@cast<f64>(@cast<f32>(v)), true));
    compare("%.0f", std::fmt::format("{:.0}", v), @cast<usize>(snprintf(&buf[0], 1600, "%.0f", v)));
    compare("%.1f", std::fmt::format("{:.1}", v), @cast<usize>(snprintf(&buf[0], 1600, "%.1f", v)));
    compare("%.2f", std::fmt::format("{:.2}", v), @cast<usize>(snprintf(&buf[0], 1600, "%.2f", v)));
    compare("%.3f", std::fmt::format("{:.3}", v), @cast<usize>(snprintf(&buf[0], 1600, "%.3f", v)));
    compare("%.6f", std::fmt::format("{:.6}", v), @cast<usize>(snprintf(&buf[0], 1600, "%.6f", v)));
    compare("%.17f", std::fmt::format("{:.17}", v), @cast<usize>(snprintf(&buf[0], 1600, "%.17f", v)));
    compare("%.40f", std::fmt::format("{:.40}", v), @cast<usize>(snprintf(&buf[0], 1600, "%.40f", v)));
    compare("%+012.3f", std::fmt::format("{:+012.3}", v), @cast<usize>(snprintf(&buf[0], 1600, "%+012.3f", v)));
    compare("%14.4f", std::fmt::format("{:>14.4}", v), @cast<usize>(snprintf(&buf[0], 1600, "%14.4f", v)));
    compare("%-14.2f", std::fmt::format("{:<14.2}", v), @cast<usize>(snprintf(&buf[0], 1600, "%-14.2f", v)));
    compare("%.0e", std::fmt::format("{:.0e}", v), volt_exp(@cast<usize>(snprintf(&buf[0], 1600, "%.0e", v))));
    compare("%.1e", std::fmt::format("{:.1e}", v), volt_exp(@cast<usize>(snprintf(&buf[0], 1600, "%.1e", v))));
    compare("%.3e", std::fmt::format("{:.3e}", v), volt_exp(@cast<usize>(snprintf(&buf[0], 1600, "%.3e", v))));
    compare("%.8E", std::fmt::format("{:.8E}", v), volt_exp(@cast<usize>(snprintf(&buf[0], 1600, "%.8E", v))));
    compare("%.16e", std::fmt::format("{:.16e}", v), volt_exp(@cast<usize>(snprintf(&buf[0], 1600, "%.16e", v))));
    compare("%.25e", std::fmt::format("{:.25e}", v), volt_exp(@cast<usize>(snprintf(&buf[0], 1600, "%.25e", v))));
    compare("%+15.5e", std::fmt::format("{:+15.5e}", v), right(volt_exp(@cast<usize>(snprintf(&buf[0], 1600, "%+.5e", v))), 15));
}

// the long ones: past 1074 fraction digits an f64's expansion is all zeros, and 767 significant
// digits is the most one has
fn long_floats(v: f64) -> void {
    if (v != v) {
        return;
    }
    compare("%.1080f", std::fmt::format("{:.1080}", v), @cast<usize>(snprintf(&buf[0], 1600, "%.1080f", v)));
    compare("%.1200f", std::fmt::format("{:.1200}", v), @cast<usize>(snprintf(&buf[0], 1600, "%.1200f", v)));
    compare("%.800e", std::fmt::format("{:.800e}", v), volt_exp(@cast<usize>(snprintf(&buf[0], 1600, "%.800e", v))));
    compare("%.1150e", std::fmt::format("{:.1150e}", v), volt_exp(@cast<usize>(snprintf(&buf[0], 1600, "%.1150e", v))));
}

fn ints(v: u64) -> void {
    val s = @cast<i64>(v);
    compare("%llx", std::fmt::format("{:x}", v), @cast<usize>(snprintf(&buf[0], 1600, "%llx", v)));
    compare("%llX", std::fmt::format("{:X}", v), @cast<usize>(snprintf(&buf[0], 1600, "%llX", v)));
    compare("%llo", std::fmt::format("{:o}", v), @cast<usize>(snprintf(&buf[0], 1600, "%llo", v)));
    compare("%lld", std::fmt::format("{:x}", s), @cast<usize>(snprintf(&buf[0], 1600, "%llx", s)));
    compare("%+lld", std::fmt::format("{:+}", s), @cast<usize>(snprintf(&buf[0], 1600, "%+lld", s)));
    compare("%024lld", std::fmt::format("{:024}", s), @cast<usize>(snprintf(&buf[0], 1600, "%024lld", s)));
    compare("%-24llu", std::fmt::format("{:<24}", v), @cast<usize>(snprintf(&buf[0], 1600, "%-24llu", v)));
    if (v != 0) {
        compare("%#llx", std::fmt::format("{:#x}", v), @cast<usize>(snprintf(&buf[0], 1600, "%#llx", v)));
    }
}

// 128-bit integers, against snprintf of their two 64-bit halves (decimal: of v / 10^19 and v % 10^19)
fn ints128(v: u128) -> void {
    val lo = @cast<u64>(v);
    val hi = @cast<u64>(v >> 64);
    var n: usize = 0;
    if (hi == 0) {
        n = @cast<usize>(snprintf(&buf[0], 1600, "%llx", lo));
    } else {
        n = @cast<usize>(snprintf(&buf[0], 1600, "%llx%016llx", hi, lo));
    }
    compare("u128 x", std::fmt::format("{:x}", v), n);
    val big: u128 = 10000000000000000000;
    val top = v / big;
    if (top == 0) {
        n = @cast<usize>(snprintf(&buf[0], 1600, "%llu", @cast<u64>(v)));
    } else if (top < big) {
        n = @cast<usize>(snprintf(&buf[0], 1600, "%llu%019llu", @cast<u64>(top), @cast<u64>(v % big)));
    } else {
        n = @cast<usize>(snprintf(&buf[0], 1600, "%llu%019llu%019llu", @cast<u64>(top / big), @cast<u64>(top % big), @cast<u64>(v % big)));
    }
    compare("u128", std::fmt::format("{}", v), n);
    compare("u128 {:>45}", std::fmt::format("{:>45}", v), right(n, 45));
    // as an i128: a minus sign and the magnitude
    val s = @cast<i128>(v);
    if (s < 0) {
        val m = 0 -% v;
        val mt = m / big;
        if (mt == 0) {
            n = @cast<usize>(snprintf(&buf[0], 1600, "-%llu", @cast<u64>(m)));
        } else if (mt < big) {
            n = @cast<usize>(snprintf(&buf[0], 1600, "-%llu%019llu", @cast<u64>(mt), @cast<u64>(m % big)));
        } else {
            n = @cast<usize>(snprintf(&buf[0], 1600, "-%llu%019llu%019llu", @cast<u64>(mt / big), @cast<u64>(mt % big), @cast<u64>(m % big)));
        }
        compare("i128", std::fmt::format("{}", s), n);
        compare("i128 {:+}", std::fmt::format("{:+}", s), n);
    }
}

fn main() -> void {
    val all: u128 = 0;
    ints128(all);
    ints128(all -% 1);
    ints128(@cast<u128>(1) << 127);
    ints128((@cast<u128>(1) << 127) - 1);
    for (i) in 0..3000 {
        val r = rnd();
        floats(from_bits(r));
        floats(@cast<f64>(r % 1000000) / 1000.0);
        floats(@cast<f64>(r % 100000) + 0.5);     // ties at .0
        floats(@cast<f64>(r % 100000) / 8.0);     // ties at .1, .2
        floats(@cast<f64>(r % 1000000000000000) * 1000000.0);
        ints(r);
        ints(r % 1000);
        ints128((@cast<u128>(r) << 64) | @cast<u128>(rnd()));
        ints128(@cast<u128>(rnd()) << @cast<u128>(r % 70));
        if (i % 30 == 0) {
            long_floats(from_bits(r));
            long_floats(from_bits(r % 4503599627370496)); // subnormals
        }
    }
    val edges: f64[11] = { 0.0, -0.0, 0.5, 1.5, 2.5, -2.5, 0.125, 1e300, 1e-300, 5e-324, 1.7976931348623157e308 };
    for (v) in edges {
        floats(v);
        long_floats(v);
    }
    std::println("bad {}, checked {} formats", bad, checked > 200000);
}
// expect: bad 0, checked true formats
