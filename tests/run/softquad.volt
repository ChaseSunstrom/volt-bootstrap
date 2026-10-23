use std::io;
// std::softfloat's f128 operations (what aarch64 macOS links for f128 arithmetic) against this host's
// own f128 (libgcc's soft routines on x86-64 and aarch64 Linux), bit for bit, on edge values and
// random bits weighted toward the hard cases. A NaN only has to be a NaN: libgcc's payloads and
// default NaN's sign differ between hosts

var state: u64 = 0x9E3779B97F4A7C15;
fn rnd() -> u64 {
    state = state ^ (state << 13);
    state = state ^ (state >> 7);
    state = state ^ (state << 17);
    return state;
}

fn rnd128() -> u128 {
    return (@cast<u128>(rnd()) << 64) | @cast<u128>(rnd());
}

fn bits(v: f128) -> u128 { return @bitcast<u128>(v); }
fn quad(b: u128) -> f128 { return @bitcast<f128>(b); }

val FRAC: u128 = 0x0000FFFFFFFFFFFFFFFFFFFFFFFFFFFF;

fn mk(sign: u128, exp: u128, frac: u128) -> u128 {
    return (sign << 127) | (exp << 112) | (frac & FRAC);
}

var bad: i32 = 0;
var checked: i32 = 0;

fn report(what: str, a: u128, b: u128, got: u128, want: u128) -> void {
    bad += 1;
    if (bad <= 8) {
        std::println("{} {:x} {:x}: got {:x} want {:x}", what, a, b, got, want);
    }
}

// float results: equal bits, or both NaN
fn same(what: str, a: u128, b: u128, got: u128, want: u128, nan_got: bool, nan_want: bool) -> void {
    checked += 1;
    if (got != want && !(nan_got && nan_want)) {
        report(what, a, b, got, want);
    }
}

fn same_q(what: str, a: u128, b: u128, got: u128, want: u128) -> void {
    same(what, a, b, got, want, std::softfloat::is_nan128(got), std::softfloat::is_nan128(want));
}

// integer results and comparisons: equal
fn same_i(what: str, a: u128, got: u128, want: u128) -> void {
    checked += 1;
    if (got != want) {
        report(what, a, 0, got, want);
    }
}

fn order(x: f128, y: f128) -> i32 {
    if (x < y) {
        return -1;
    }
    if (x == y) {
        return 0;
    }
    if (x > y) {
        return 1;
    }
    return 2;
}

fn flag(c: bool) -> u128 {
    if (c) {
        return 1;
    }
    return 0;
}

// a random f128's bits, often at an edge
fn pick() -> u128 {
    val kind = rnd() % 10;
    val sign = @cast<u128>(rnd() & 1);
    var exp = @cast<u128>(rnd() % 32767);
    if (kind == 0) {
        exp = 0; // subnormal or zero
    } else if (kind == 1) {
        exp = 32767; // inf or NaN
    } else if (kind == 2) {
        exp = @cast<u128>((rnd() % 8) + 16380); // near 1
    } else if (kind == 3) {
        exp = @cast<u128>(rnd() % 120); // near the subnormals: products underflow
    } else if (kind == 4) {
        exp = @cast<u128>(32766 - (rnd() % 120)); // near the largest: products overflow
    }
    var frac = rnd128();
    val f = rnd() % 5;
    if (f == 0) {
        frac = 0;
    } else if (f == 1) {
        frac &= ~((@cast<u128>(1) << 64) - 1); // short fractions: exact sums, ties
    } else if (f == 2) {
        frac = FRAC; // all ones: carries
    }
    return mk(sign, exp, frac);
}

// b near a: the same or a nearby exponent, a few ulps apart (cancellation, ties)
fn near(a: u128) -> u128 {
    val k = rnd() % 4;
    if (k == 0) {
        return a +% @cast<u128>(rnd() % 4);
    }
    if (k == 1) {
        return a -% @cast<u128>(rnd() % 4);
    }
    if (k == 2) {
        return a ^ (@cast<u128>(1) << 127);
    }
    return mk(@cast<u128>(rnd() & 1), ((a >> 112) & 32767) ^ @cast<u128>(rnd() % 3), rnd128());
}

fn arith(a: u128, b: u128) -> void {
    val x = quad(a);
    val y = quad(b);
    same_q("add", a, b, std::softfloat::add128(a, b), bits(x + y));
    same_q("sub", a, b, std::softfloat::sub128(a, b), bits(x - y));
    same_q("mul", a, b, std::softfloat::mul128(a, b), bits(x * y));
    // Windows' quad routines are compiler-rt's (llvm-mingw), whose __divtf3 rounds a subnormal
    // quotient wrongly (0x2961 0... / 0x69cc f... is exactly 0x4; it gives 0x6; 0x94e6 0... /
    // 0xd554 f... is just over half the smallest subnormal, so 0x1; it gives 0): those are left out
    val q = bits(x / y);
    val s = std::softfloat::div128(a, b);
    var sub = false;
    comptime if (@cfg("os", "windows")) {
        sub = (q & 0x7FFF0000000000000000000000000000) == 0 && (s & 0x7FFF0000000000000000000000000000) == 0 && ((q | s) & FRAC) != 0;
    }
    if (!sub) {
        same_q("div", a, b, s, q);
    }
    same_i("cmp", a, @cast<u128>(std::softfloat::cmp128(a, b) + 10), @cast<u128>(order(x, y) + 10));
    val c = std::softfloat::cmp128(a, b);
    same_i("eq", a, flag(c == 0), flag(x == y));
    same_i("ne", a, flag(c != 0), flag(x != y));
    same_i("lt", a, flag(c == -1), flag(x < y));
    same_i("le", a, flag(c == -1 || c == 0), flag(x <= y));
    same_i("gt", a, flag(c == 1), flag(x > y));
    same_i("ge", a, flag(c == 1 || c == 0), flag(x >= y));
    same_i("unord", a, flag(c == 2), flag(x != x || y != y));
}

// conversions of one value, with exponents near each narrower type's range
fn convert(a: u128) -> void {
    val x = quad(a);
    val h = std::softfloat::f128_to_f16(a);
    same("to_f16", a, 0, @cast<u128>(h), @cast<u128>(@bitcast<u16>(@cast<f16>(x))), (h & 0x7FFF) > 0x7C00, @cast<f16>(x) != @cast<f16>(x));
    val s = std::softfloat::f128_to_f32(a);
    same("to_f32", a, 0, @cast<u128>(s), @cast<u128>(@bitcast<u32>(@cast<f32>(x))), (s & 0x7FFFFFFF) > 0x7F800000, @cast<f32>(x) != @cast<f32>(x));
    val d = std::softfloat::f128_to_f64(a);
    same("to_f64", a, 0, @cast<u128>(d), @cast<u128>(@bitcast<u64>(@cast<f64>(x))), std::softfloat::is_nan(d), @cast<f64>(x) != @cast<f64>(x));
    // to integers, where the value fits (past it they saturate: checked below)
    val e = @cast<i32>((a >> 112) & 32767) - 16383;
    val neg = (a >> 127) != 0;
    if (e < 31) {
        same_i("to_i32", a, @cast<u128>(@cast<u32>(@cast<i32>(std::softfloat::f128_to_signed(a, 32)))), @cast<u128>(@cast<u32>(@cast<i32>(x))));
    }
    if (e < 63) {
        same_i("to_i64", a, @cast<u128>(@cast<u64>(@cast<i64>(std::softfloat::f128_to_signed(a, 64)))), @cast<u128>(@cast<u64>(@cast<i64>(x))));
    }
    if (e < 127) {
        same_i("to_i128", a, @cast<u128>(std::softfloat::f128_to_signed(a, 128)), @cast<u128>(@cast<i128>(x)));
    }
    if (e < 32 && !neg) {
        same_i("to_u32", a, std::softfloat::f128_to_unsigned(a, 32), @cast<u128>(@cast<u32>(x)));
    }
    if (e < 64 && !neg) {
        same_i("to_u64", a, std::softfloat::f128_to_unsigned(a, 64), @cast<u128>(@cast<u64>(x)));
    }
    if (e < 128 && !neg) {
        same_i("to_u128", a, std::softfloat::f128_to_unsigned(a, 128), @cast<u128>(x));
    }
}

fn near_exp(a: u128, mid: i32, span: i32) -> u128 {
    val e = mid + @cast<i32>(rnd() % @cast<u64>(2 * span)) - span;
    return (a & ~(@cast<u128>(32767) << 112)) | (@cast<u128>(e) << 112);
}

fn from_ints(v: u128) -> void {
    val n = v >> @cast<u128>(rnd() % 128); // every width
    val sn = @cast<i128>(n);
    same_q("u128", n, 0, std::softfloat::u128_to_f128(false, n), bits(@cast<f128>(n)));
    same_q("i128", n, 0, std::softfloat::i128_to_f128(sn), bits(@cast<f128>(sn)));
    val n64 = @cast<u64>(n);
    same_q("u64", n, 0, std::softfloat::u128_to_f128(false, @cast<u128>(n64)), bits(@cast<f128>(n64)));
    same_q("i64", n, 0, std::softfloat::i128_to_f128(@cast<i128>(@cast<i64>(n64))), bits(@cast<f128>(@cast<i64>(n64))));
    val n32 = @cast<u32>(n);
    same_q("u32", n, 0, std::softfloat::u128_to_f128(false, @cast<u128>(n32)), bits(@cast<f128>(n32)));
    same_q("i32", n, 0, std::softfloat::i128_to_f128(@cast<i128>(@cast<i32>(n32))), bits(@cast<f128>(@cast<i32>(n32))));
}

fn main() -> void {
    // ±0, the smallest and largest subnormals, the smallest normal, 1 and its neighbours, 1.5, 3,
    // the largest finite, inf, a quiet and a signaling NaN, and values one ulp apart
    var edges: std::vec<u128> = {};
    val raw: u128[] = {
        0, 1, FRAC, mk(0, 1, 0), mk(0, 16383, 0), mk(0, 16383, 1), mk(0, 16382, FRAC),
        mk(0, 16383, @cast<u128>(1) << 111), mk(0, 16384, @cast<u128>(1) << 111), mk(0, 32766, FRAC),
        mk(0, 32767, 0), mk(0, 32767, @cast<u128>(1) << 111), mk(0, 32767, 1), mk(0, 16383, 3),
        mk(0, 16495, 1), mk(0, 16271, 0), mk(0, 0, @cast<u128>(1) << 111),
    };
    for (i) in 0..raw.len {
        edges.push(raw[i]);
        edges.push(raw[i] | (@cast<u128>(1) << 127));
    }
    for (a&) in edges.items() {
        for (b&) in edges.items() {
            arith(*a, *b);
        }
        convert(*a);
    }
    // rounding ties: 1 + 2^-113 rounds to even (down), 1 + 3 * 2^-113 up; halfway sums and products
    same_q("tie down", 0, 0, std::softfloat::add128(mk(0, 16383, 0), mk(0, 16270, 0)), mk(0, 16383, 0));
    same_q("tie up", 0, 0, std::softfloat::add128(mk(0, 16383, 1), mk(0, 16270, 0)), mk(0, 16383, 2));
    for (i) in 0..25000 {
        val a = pick();
        var b = pick();
        if ((rnd() % 3) == 0) {
            b = near(a);
        }
        arith(a, b);
        // products and quotients landing among the subnormals, rounding there (the random
        // exponents above reach them rarely): b's exponent set so the result's is near 0
        val ea = @cast<i64>((a >> 112) & 32767);
        val d = @cast<i64>(rnd() % 118) - 3;
        val keep = ~(@cast<u128>(32767) << 112);
        val em = 16383 - ea - d;
        if (ea >= 1 && em >= 1 && em <= 32766) {
            arith(a, (b & keep) | (@cast<u128>(em) << 112));
        }
        val ed = ea + 16383 + d;
        if (ea >= 1 && ed >= 1 && ed <= 32766) {
            arith(a, (b & keep) | (@cast<u128>(ed) << 112));
        }
        convert(a);
        convert(near_exp(a, 16383, 40));
        convert(near_exp(a, 16383, 160));
        convert(near_exp(a, 16383, 1100));
        from_ints(rnd128());
        // narrower floats widen exactly
        val d = rnd();
        same_q("from_f64", @cast<u128>(d), 0, std::softfloat::f64_to_f128(d), bits(@cast<f128>(@bitcast<f64>(d))));
        val s = @cast<u32>(rnd());
        same_q("from_f32", @cast<u128>(s), 0, std::softfloat::f32_to_f128(s), bits(@cast<f128>(@bitcast<f32>(s))));
    }
    for (i) in 0..65536 {
        val h = @cast<u16>(i);
        same_q("from_f16", @cast<u128>(h), 0, std::softfloat::f16_to_f128(h), bits(@cast<f128>(@bitcast<f16>(h))));
    }
    // past the integer types' ranges a conversion saturates as compiler-rt's does (the host's own
    // casts can't be the oracle there); NaN gives the largest, a negative 0 when unsigned
    val two63 = mk(0, 16383 + 63, 0);
    val two127 = mk(0, 16383 + 127, 0);
    val inf = mk(0, 32767, 0);
    val nan = mk(0, 32767, @cast<u128>(1) << 111);
    val ones = ~@cast<u128>(0);
    same_i("2^63 to i64", two63, @cast<u128>(std::softfloat::f128_to_signed(two63, 64)), 0x7FFFFFFFFFFFFFFF);
    same_i("-2^63 to i64", two63, @cast<u128>(std::softfloat::f128_to_signed(two63 | (@cast<u128>(1) << 127), 64)), ones << 63);
    same_i("-inf to i32", inf, @cast<u128>(std::softfloat::f128_to_signed(inf | (@cast<u128>(1) << 127), 32)), ones << 31);
    same_i("inf to i128", inf, @cast<u128>(std::softfloat::f128_to_signed(inf, 128)), ones >> 1);
    same_i("-2^127 to i128", two127, @cast<u128>(std::softfloat::f128_to_signed(two127 | (@cast<u128>(1) << 127), 128)), @cast<u128>(1) << 127);
    same_i("NaN to i64", nan, @cast<u128>(std::softfloat::f128_to_signed(nan, 64)), 0x7FFFFFFFFFFFFFFF);
    same_i("-NaN to i64", nan, @cast<u128>(std::softfloat::f128_to_signed(nan | (@cast<u128>(1) << 127), 64)), ones << 63);
    same_i("-NaN to u32", nan, std::softfloat::f128_to_unsigned(nan | (@cast<u128>(1) << 127), 32), 0);
    same_i("2^127 to u128", two127, std::softfloat::f128_to_unsigned(two127, 128), @cast<u128>(1) << 127);
    same_i("inf to u128", inf, std::softfloat::f128_to_unsigned(inf, 128), ones);
    same_i("2^64 to u64", 0, std::softfloat::f128_to_unsigned(mk(0, 16383 + 64, 0), 64), 0xFFFFFFFFFFFFFFFF);
    same_i("-1 to u32", 0, std::softfloat::f128_to_unsigned(mk(1, 16383, 0), 32), 0);
    std::println("bad {}, checked over 1M: {}", bad, checked > 1000000);
}
// expect: bad 0, checked over 1M: true
