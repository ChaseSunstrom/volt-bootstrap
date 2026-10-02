use std::io;
// str.parse_float (std/text.volt, in Volt) against libc's strtod, bit for bit: shortest and long
// renderings of random doubles, random digit strings with big and small exponents, and the exact
// midpoints between neighbouring doubles, on them and a hair either side (ties go to even), with
// over a thousand digits

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

fn bits(v: f64) -> u64 {
    var r: u64 = 0;
    var x = v;
    val from = @slice(@cast<u8*>(&x), 8);
    val to = @slice(@cast<u8*>(&r), 8);
    for (i) in 0..8 {
        to[i] = from[i];
    }
    return r;
}

var checked: u64 = 0;
var bad: u64 = 0;
var buf: u8[3200];

// buf's first n bytes, parsed both ways
fn check(n: usize) -> void {
    buf[n] = 0;
    val s = @cast<str>(@slice(&buf[0], n));
    val want = bits(strtod(@cast<cstr>(&buf[0]), null));
    checked += 1;
    val got = s.parse_float() catch {
        bad += 1;
        if (bad <= 10) {
            std::println("BAD {}: an error", s);
        }
        return;
    };
    if (bits(got) != want) {
        bad += 1;
        if (bad <= 10) {
            std::println("BAD {}: strtod {:x} volt {:x}", s, want, bits(got));
        }
    }
}

fn put(n: usize, s: str) -> usize {
    for (c, i) in s {
        buf[n + i] = c;
    }
    return n + s.len;
}

fn renderings(v: f64) -> void {
    val shortest = std::fmt::format("{}", v);
    check(put(0, shortest.as_str()));
    check(@cast<usize>(snprintf(&buf[0], 3200, "%.17g", v)));
    check(@cast<usize>(snprintf(&buf[0], 3200, "%.*e", @cast<i32>(rnd() % 30), v)));
    check(@cast<usize>(snprintf(&buf[0], 3200, "%.*e", @cast<i32>(rnd() % 30), -v)));
}

// a random decimal: up to 40 digits, maybe a point, maybe an exponent
fn random_decimal() -> void {
    var n: usize = 0;
    if (rnd() % 2 == 0) {
        buf[0] = '-';
        n = 1;
    }
    val digits = 1 + rnd() % 40;
    val point = rnd() % (digits + 3);
    for (i) in 0..digits {
        if (i == point) {
            buf[n] = '.';
            n += 1;
        }
        // runs of zeros and nines are where rounding goes wrong
        val kind = rnd() % 4;
        if (kind == 0) {
            buf[n] = '0';
        } else if (kind == 1) {
            buf[n] = '9';
        } else {
            buf[n] = @cast<u8>(rnd() % 10) + '0';
        }
        n += 1;
    }
    if (rnd() % 3 != 0) {
        val e = @cast<i64>(rnd() % 760) - 380;
        n += @cast<usize>(snprintf(&buf[n], 64, "e%lld", e));
    }
    check(n);
}

var xs: u8[1600];
var ys: u8[1600];

// the exact midpoint between the positive doubles x and the next one up, on it, just above and just
// below. Each is printed exactly with 1100 places in 1500 columns, added digit by digit and halved
fn midpoints(x: f64) -> void {
    val y = from_bits(bits(x) + 1);
    if (bits(y) == 0x7FF0000000000000) {
        return; // past the largest double is infinity
    }
    snprintf(&xs[0], 1600, "%01500.1100f", x);
    snprintf(&ys[0], 1600, "%01500.1100f", y);
    var carry: u8 = 0;
    var i: usize = 1500;
    while (i > 0) {
        i -= 1;
        if (xs[i] == '.') {
            buf[i] = '.';
        } else {
            val d = (xs[i] - '0') + (ys[i] - '0') + carry;
            buf[i] = d % 10 + '0';
            carry = d / 10;
        }
    }
    var rem: u8 = 0;
    for (k) in 0..1500 {
        if (buf[k] != '.') {
            val d = rem * 10 + (buf[k] - '0');
            buf[k] = d / 2 + '0';
            rem = d % 2;
        }
    }
    check(1500);
    // above: a 1 past the last place
    buf[1500] = '1';
    check(1501);
    // the first 19 digits, then 30 nines: above the midpoint, though the 19 alone are below it
    for (k) in 0..1500 {
        xs[k] = buf[k];
    }
    var sig: usize = 0;
    for (k) in 0..1500 {
        if (buf[k] != '.' && (sig > 0 || buf[k] != '0')) {
            sig += 1;
            if (sig > 49) {
                buf[k] = '0';
            } else if (sig > 19) {
                buf[k] = '9';
            }
        }
    }
    check(1500);
    for (k) in 0..1500 {
        buf[k] = xs[k];
    }
    // below: one off the last place
    var k: usize = 1500;
    while (k > 0) {
        k -= 1;
        if (buf[k] == '.') {
            continue;
        }
        if (buf[k] != '0') {
            buf[k] -= 1;
            break;
        }
        buf[k] = '9';
    }
    check(1500);
}

fn text(s: str) -> void {
    check(put(0, s));
}

fn shows(s: str) -> void {
    val r = s.parse_float();
    std::println("{}: {}", s, r);
}

fn fails(s: str) -> bool {
    val v = std::json::parse(s) catch return true;
    return false;
}

fn main() -> void {
    for (i) in 0..20000 {
        val r = rnd();
        if (from_bits(r) == from_bits(r)) {
            renderings(from_bits(r));
        }
        renderings(from_bits(r % 4503599627370496)); // subnormals
        renderings(@cast<f64>(r % 1000000) / 1000.0);
        random_decimal();
        random_decimal();
        if (i % 20 == 0) {
            val x = from_bits(r & 0x7FEFFFFFFFFFFFFF);
            if (x > 0.0 && x < 1.7976931348623157e308) {
                midpoints(x);
            }
            midpoints(from_bits(r % 4503599627370496 + 1));
        }
    }
    val edges: f64[8] = { 5e-324, 2.2250738585072014e-308, 2.2250738585072009e-308, 1.7976931348623157e308, 1.0, 9007199254740992.0, 0.1, 1e23 };
    for (v) in edges {
        renderings(v);
        midpoints(v);
    }
    text("0");
    text("-0");
    text("0e999999");
    text("-0.0e-5");
    text("1e-400");
    text("-1e400");
    text("2.4703282292062327e-324");
    text("2.4703282292062328e-324");
    text("1.7976931348623158e308");
    text("1.7976931348623159e308");
    text("9007199254740993");
    text("9007199254740995");
    text("123456789012345678901234567890");
    text("00000.0000001e7");
    text(".5");
    text("5.");
    text("+3.25E+2");
    text("1e23");
    text("8.533e+68");
    text("4.1006e-184");
    text("9.998e+307");
    text("9.9538452227e-280");
    text("6.47660115e-260");
    text("7.4e+47");
    text("5.92e+48");
    text("7.35e+66");
    text("8.32116e+55");
    // over 800 digits before the point, then an exponent that brings it back
    var n: usize = 0;
    buf[0] = '1';
    for (k) in 1..900 {
        buf[k] = '0';
    }
    n = put(900, "e-850");
    check(n);
    buf[450] = '7';
    check(n);
    // a long run of zeros after the point
    n = put(0, "0.");
    for (k) in 0..1000 {
        buf[n + @cast<usize>(k)] = '0';
    }
    n = put(n + 1000, "25e1000");
    check(n);
    shows("inf");
    shows("-Infinity");
    shows("nan");
    shows("1e");
    shows("1e+");
    shows("e5");
    shows(".");
    shows("-");
    shows("+.e1");
    shows("1.2.3");
    shows("0x10");
    shows(" 1");
    shows("1 ");
    shows("");
    val nan_bits = bits("-nan".parse_float() catch 0.0);
    std::println("-nan sign {}", nan_bits >> 63);
    // JSON numbers come through the same code
    val j = std::json::parse("[0.1, -2e-3, 1e400, 17976931348623157e292]") catch @panic("json");
    std::println("{}", j.text());
    std::println("{} {} {}", fails("1.5x"), fails("+1"), fails("1..5"));
    std::println("bad {}, checked {} strings", bad, checked > 100000);
}
// expect: inf: inf
// expect: -Infinity: -inf
// expect: nan: nan
// expect: 1e: error.INVALID
// expect: 1e+: error.INVALID
// expect: e5: error.INVALID
// expect: .: error.INVALID
// expect: -: error.INVALID
// expect: +.e1: error.INVALID
// expect: 1.2.3: error.INVALID
// expect: 0x10: error.INVALID
// expect:  1: error.INVALID
// expect: 1 : error.INVALID
// expect: : error.EMPTY
// expect: -nan sign 1
// expect: [0.1,-0.002,null,1.7976931348623157e+308]
// expect: true true true
// expect: bad 0, checked true strings
