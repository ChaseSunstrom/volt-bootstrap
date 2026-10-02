use std::io;
// std::softfloat (integer-only IEEE arithmetic, for cores without an FPU) against this CPU's own
// floating point, bit for bit, on random bits weighted toward the hard cases (subnormals, huge and
// tiny exponents, infinities, zeros, NaNs, nearby values) and on conversions. A NaN only has to be
// a NaN: payloads differ between CPUs

var state: u64 = 88172645463325252;
fn rnd() -> u64 {
    state = state ^ (state << 13);
    state = state ^ (state >> 7);
    state = state ^ (state << 17);
    return state;
}

fn f64_of(b: u64) -> f64 {
    var r: f64 = 0.0;
    var x = b;
    val from = @slice(@cast<u8*>(&x), 8);
    val to = @slice(@cast<u8*>(&r), 8);
    for (i) in 0..8 {
        to[i] = from[i];
    }
    return r;
}

fn bits64(v: f64) -> u64 {
    var r: u64 = 0;
    var x = v;
    val from = @slice(@cast<u8*>(&x), 8);
    val to = @slice(@cast<u8*>(&r), 8);
    for (i) in 0..8 {
        to[i] = from[i];
    }
    return r;
}

fn f32_of(b: u32) -> f32 {
    var r: f32 = 0.0;
    var x = b;
    val from = @slice(@cast<u8*>(&x), 4);
    val to = @slice(@cast<u8*>(&r), 4);
    for (i) in 0..4 {
        to[i] = from[i];
    }
    return r;
}

fn bits32(v: f32) -> u32 {
    var r: u32 = 0;
    var x = v;
    val from = @slice(@cast<u8*>(&x), 4);
    val to = @slice(@cast<u8*>(&r), 4);
    for (i) in 0..4 {
        to[i] = from[i];
    }
    return r;
}

// a random f64's bits, often at an edge
fn pick64() -> u64 {
    val r = rnd();
    val kind = r % 8;
    val sign = (rnd() & 1) << 63;
    var exp = (rnd() % 2047) << 52;
    if (kind == 0) {
        exp = 0; // subnormal or zero
    } else if (kind == 1) {
        exp = 2047 << 52; // inf or NaN
    } else if (kind == 2) {
        exp = ((rnd() % 6) + 1020) << 52; // near 1
    }
    var frac = rnd() & 0x000FFFFFFFFFFFFF;
    if ((rnd() % 4) == 0) {
        frac = 0;
    } else if ((rnd() % 4) == 0) {
        frac &= 0x000FFFFFFFF00000; // short fractions: exact sums, ties
    }
    return sign | exp | frac;
}

fn pick32() -> u32 {
    val sign = @cast<u32>(rnd() & 1) << 31;
    var exp = @cast<u32>(rnd() % 255) << 23;
    val kind = rnd() % 8;
    if (kind == 0) {
        exp = 0;
    } else if (kind == 1) {
        exp = 255 << 23;
    } else if (kind == 2) {
        exp = @cast<u32>((rnd() % 6) + 124) << 23;
    }
    var frac = @cast<u32>(rnd()) & 0x007FFFFF;
    if ((rnd() % 4) == 0) {
        frac = 0;
    } else if ((rnd() % 4) == 0) {
        frac &= 0x007FF000;
    }
    return sign | exp | frac;
}

var checked: u64 = 0;
var bad: u64 = 0;

fn same64(what: str, a: u64, b: u64, got: u64, want: u64) -> void {
    checked += 1;
    if (got == want || (std::softfloat::is_nan(got) && std::softfloat::is_nan(want))) {
        return;
    }
    bad += 1;
    if (bad <= 20) {
        std::println("BAD {} {:x} {:x}: got {:x} want {:x}", what, a, b, got, want);
    }
}

fn same32(what: str, a: u32, b: u32, got: u32, want: u32) -> void {
    checked += 1;
    val nan_g = (got & 0x7FFFFFFF) > 0x7F800000;
    val nan_w = (want & 0x7FFFFFFF) > 0x7F800000;
    if (got == want || (nan_g && nan_w)) {
        return;
    }
    bad += 1;
    if (bad <= 20) {
        std::println("BAD {} {:x} {:x}: got {:x} want {:x}", what, a, b, got, want);
    }
}

fn order(x: f64, y: f64) -> i32 {
    if (x != x || y != y) {
        return 2;
    }
    if (x < y) {
        return -1;
    }
    if (x == y) {
        return 0;
    }
    return 1;
}

fn main() -> void {
    for (i) in 0..400000 {
        val a = pick64();
        var b = pick64();
        if (i % 5 == 0) {
            b = a ^ (rnd() & 7); // neighbours: cancellation, ties
        }
        val x = f64_of(a);
        val y = f64_of(b);
        same64("add", a, b, std::softfloat::add64(a, b), bits64(x + y));
        same64("sub", a, b, std::softfloat::sub64(a, b), bits64(x - y));
        same64("mul", a, b, std::softfloat::mul64(a, b), bits64(x * y));
        same64("div", a, b, std::softfloat::div64(a, b), bits64(x / y));
        same64("cmp", a, b, @cast<u64>(std::softfloat::cmp64(a, b) + 10), @cast<u64>(order(x, y) + 10));
        same32("f64_to_f32", @cast<u32>(a >> 32), 0, std::softfloat::f64_to_f32(a), bits32(@cast<f32>(x)));

        val c = pick32();
        var d = pick32();
        if (i % 5 == 0) {
            d = c ^ (@cast<u32>(rnd()) & 7);
        }
        val p = f32_of(c);
        val q = f32_of(d);
        same32("add32", c, d, std::softfloat::add32(c, d), bits32(p + q));
        same32("sub32", c, d, std::softfloat::sub32(c, d), bits32(p - q));
        same32("mul32", c, d, std::softfloat::mul32(c, d), bits32(p * q));
        same32("div32", c, d, std::softfloat::div32(c, d), bits32(p / q));
        same64("f32_to_f64", @cast<u64>(c), 0, std::softfloat::f32_to_f64(c), bits64(@cast<f64>(p)));

        // integers to floats, every width of them
        val n = rnd() >> (rnd() % 64);
        val sn = @cast<i64>(rnd()) >> @cast<i64>(rnd() % 64);
        same64("u64_to_f64", n, 0, std::softfloat::u64_to_f64(false, n), bits64(@cast<f64>(n)));
        same64("i64_to_f64", @cast<u64>(sn), 0, std::softfloat::i64_to_f64(sn), bits64(@cast<f64>(sn)));
        same32("u64_to_f32", @cast<u32>(n), 0, std::softfloat::u64_to_f32(false, n), bits32(@cast<f32>(n)));
        same32("i64_to_f32", @cast<u32>(sn), 0, std::softfloat::i64_to_f32(sn), bits32(@cast<f32>(sn)));

        // floats to integers, where the value fits
        val e = (a >> 52) & 2047;
        if (e < 1023 + 62) {
            same64("f64_to_i64", a, 0, @cast<u64>(std::softfloat::f64_to_i64(a)), @cast<u64>(@cast<i64>(x)));
        }
        if (e < 1023 + 30) {
            same64("f64_to_i32", a, 0, @cast<u64>(std::softfloat::f64_to_i32(a)), @cast<u64>(@cast<i32>(x)));
        }
        if (e < 1023 + 63 && (a >> 63) == 0) {
            same64("f64_to_u64", a, 0, std::softfloat::f64_to_u64(a), @cast<u64>(x));
        }
        if (e < 1023 + 31 && (a >> 63) == 0) {
            same64("f64_to_u32", a, 0, @cast<u64>(std::softfloat::f64_to_u32(a)), @cast<u64>(@cast<u32>(x)));
        }
    }
    // past the integer types' ranges a conversion saturates (the CPU's own casts can't be the
    // oracle there): 2^63 and up to the largest i64, -2^63 and below to the smallest, NaN and
    // negatives to 0 for unsigned, 2^64 and up to the largest u64
    same64("2^63 to i64", 0, 0, @cast<u64>(std::softfloat::f64_to_i64(0x43E0000000000000)), 0x7FFFFFFFFFFFFFFF);
    same64("-2^63 to i64", 0, 0, @cast<u64>(std::softfloat::f64_to_i64(0xC3E0000000000000)), 0x8000000000000000);
    same64("-2^64 to i64", 0, 0, @cast<u64>(std::softfloat::f64_to_i64(0xC3F0000000000000)), 0x8000000000000000);
    same64("2^64 to u64", 0, 0, std::softfloat::f64_to_u64(0x43F0000000000000), 0xFFFFFFFFFFFFFFFF);
    same64("2^64-2^11 to u64", 0, 0, std::softfloat::f64_to_u64(0x43EFFFFFFFFFFFFF), 0xFFFFFFFFFFFFF800);
    same64("-1 to u64", 0, 0, std::softfloat::f64_to_u64(0xBFF0000000000000), 0);
    same64("2^31 to i32", 0, 0, @cast<u64>(@cast<u32>(std::softfloat::f64_to_i32(0x41E0000000000000))), 0x7FFFFFFF);
    same64("-2^31 to i32", 0, 0, @cast<u64>(@cast<u32>(std::softfloat::f64_to_i32(0xC1E0000000000000))), 0x80000000);
    same64("2^32 to u32", 0, 0, @cast<u64>(std::softfloat::f64_to_u32(0x41F0000000000000)), 0xFFFFFFFF);
    same64("inf to i64", 0, 0, @cast<u64>(std::softfloat::f64_to_i64(0x7FF0000000000000)), 0x7FFFFFFFFFFFFFFF);
    same64("-inf to i64", 0, 0, @cast<u64>(std::softfloat::f64_to_i64(0xFFF0000000000000)), 0x8000000000000000);
    std::println("bad {}, checked over 6M: {}", bad, checked > 6000000);
}
// expect: bad 0, checked over 6M: true
