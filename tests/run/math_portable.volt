use std::io;
// std::math::portable (std/math_portable.volt, in Volt) against the C library's libm, in ulps, on
// edge cases (zeros, subnormals, infinities, NaN, the largest double, near pi/2 and overflow) and
// random doubles of every size; then the f32 overloads

extern "C" fn sqrt(x: f64) -> f64;
extern "C" fn cbrt(x: f64) -> f64;
extern "C" fn pow(x: f64, y: f64) -> f64;
extern "C" fn exp(x: f64) -> f64;
extern "C" fn exp2(x: f64) -> f64;
extern "C" fn expm1(x: f64) -> f64;
extern "C" fn log(x: f64) -> f64;
extern "C" fn log2(x: f64) -> f64;
extern "C" fn log10(x: f64) -> f64;
extern "C" fn sin(x: f64) -> f64;
extern "C" fn cos(x: f64) -> f64;
extern "C" fn tan(x: f64) -> f64;
extern "C" fn asin(x: f64) -> f64;
extern "C" fn acos(x: f64) -> f64;
extern "C" fn atan(x: f64) -> f64;
extern "C" fn atan2(y: f64, x: f64) -> f64;
extern "C" fn sinh(x: f64) -> f64;
extern "C" fn cosh(x: f64) -> f64;
extern "C" fn tanh(x: f64) -> f64;
extern "C" fn hypot(x: f64, y: f64) -> f64;
extern "C" fn floor(x: f64) -> f64;
extern "C" fn ceil(x: f64) -> f64;
extern "C" fn round(x: f64) -> f64;
extern "C" fn trunc(x: f64) -> f64;
extern "C" fn fmod(x: f64, y: f64) -> f64;
extern "C" fn sinf(x: f32) -> f32;
extern "C" fn expf(x: f32) -> f32;
extern "C" fn logf(x: f32) -> f32;
extern "C" fn powf(x: f32, y: f32) -> f32;
extern "C" fn sqrtf(x: f32) -> f32;
extern "C" fn atan2f(y: f32, x: f32) -> f32;
extern "C" fn fmodf(x: f32, y: f32) -> f32;
extern "C" fn floorf(x: f32) -> f32;

var bad32: u64 = 0;

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

// f32 results: within an ulp (sqrt, fmod and floor exactly)
fn same32(what: str, x: f32, want: f32, got: f32, exact: bool) -> void {
    if (want != want && got != got) {
        return;
    }
    val a = @cast<i64>(bits32(want));
    val b = @cast<i64>(bits32(got));
    var d = a - b;
    if (d < 0) {
        d = -d;
    }
    if ((exact && d != 0) || d > 1 || ((want < 0.0) != (got < 0.0) && want != got)) {
        bad32 += 1;
        if (bad32 <= 5) {
            std::println("BAD {}({:e}): libm {:e} volt {:e}", what, x, want, got);
        }
    }
}

val NAMES: str[25] = { "sqrt", "cbrt", "pow", "exp", "exp2", "expm1", "log", "log2", "log10", "sin", "cos", "tan", "asin", "acos", "atan", "atan2", "sinh", "cosh", "tanh", "hypot", "floor", "ceil", "round", "trunc", "fmod" };
// the most ulps each may be off from glibc by (0: exact). glibc's own cbrt is up to 2.1 ulps from
// the true value and its log10 1.5 (Volt's are within 0.52 on those inputs), so those two get more
val ALLOW: u64[25] = { 0, 3, 1, 1, 1, 1, 1, 1, 2, 1, 1, 1, 1, 1, 1, 1, 2, 2, 2, 1, 0, 0, 0, 0, 0 };
var worst: u64[25];
var bad: u64[25];
var count: u64[25];

var state: u64 = 88172645463325252;
fn rnd() -> u64 {
    state = state ^ (state << 13);
    state = state ^ (state >> 7);
    state = state ^ (state << 17);
    return state;
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

// position on a line where neighbouring doubles are 1 apart
fn ord(b: u64) -> u64 {
    if ((b >> 63) != 0) {
        return 0x8000000000000000 - (b & 0x7FFFFFFFFFFFFFFF);
    }
    return 0x8000000000000000 + b;
}

fn ulps(a: f64, b: f64) -> u64 {
    if (a != a || b != b) {
        if (a != a && b != b) {
            return 0;
        }
        return 0xFFFFFFFFFFFFFFFF;
    }
    val x = ord(bits(a));
    val y = ord(bits(b));
    if (x > y) {
        return x - y;
    }
    return y - x;
}

fn run(f: usize, x: f64, y: f64) -> void {
    var want = 0.0;
    var got = 0.0;
    if (f == 0) { want = sqrt(x); got = std::math::portable::sqrt(x); }
    else if (f == 1) { want = cbrt(x); got = std::math::portable::cbrt(x); }
    else if (f == 2) { want = pow(x, y); got = std::math::portable::pow(x, y); }
    else if (f == 3) { want = exp(x); got = std::math::portable::exp(x); }
    else if (f == 4) { want = exp2(x); got = std::math::portable::exp2(x); }
    else if (f == 5) { want = expm1(x); got = std::math::portable::expm1(x); }
    else if (f == 6) { want = log(x); got = std::math::portable::log(x); }
    else if (f == 7) { want = log2(x); got = std::math::portable::log2(x); }
    else if (f == 8) { want = log10(x); got = std::math::portable::log10(x); }
    else if (f == 9) { want = sin(x); got = std::math::portable::sin(x); }
    else if (f == 10) { want = cos(x); got = std::math::portable::cos(x); }
    else if (f == 11) { want = tan(x); got = std::math::portable::tan(x); }
    else if (f == 12) { want = asin(x); got = std::math::portable::asin(x); }
    else if (f == 13) { want = acos(x); got = std::math::portable::acos(x); }
    else if (f == 14) { want = atan(x); got = std::math::portable::atan(x); }
    else if (f == 15) { want = atan2(y, x); got = std::math::portable::atan2(y, x); }
    else if (f == 16) { want = sinh(x); got = std::math::portable::sinh(x); }
    else if (f == 17) { want = cosh(x); got = std::math::portable::cosh(x); }
    else if (f == 18) { want = tanh(x); got = std::math::portable::tanh(x); }
    else if (f == 19) { want = hypot(x, y); got = std::math::portable::hypot(x, y); }
    else if (f == 20) { want = floor(x); got = std::math::portable::floor(x); }
    else if (f == 21) { want = ceil(x); got = std::math::portable::ceil(x); }
    else if (f == 22) { want = round(x); got = std::math::portable::round(x); }
    else if (f == 23) { want = trunc(x); got = std::math::portable::trunc(x); }
    else { want = fmod(x, y); got = std::math::portable::fmod(x, y); }
    count[f] += 1;
    var d = ulps(want, got);
    // zeros must agree in sign too
    if (d == 0 && want == 0.0 && bits(want) != bits(got)) {
        d = 1;
    }
    if (d > worst[f]) {
        worst[f] = d;
    }
    if (d > ALLOW[f]) {
        bad[f] += 1;
        if (bad[f] <= 3) {
            std::println("BAD {}({:e}, {:e}): libm {:e} volt {:e}, {} ulps", NAMES[f], x, y, want, got, d);
        }
    }
}

// a random double of any size, sign and kind
fn any() -> f64 {
    return from_bits(rnd());
}

// uniform in [-r, r]
fn within(r: f64) -> f64 {
    return (@cast<f64>(rnd() >> 11) / 9007199254740992.0 * 2.0 - 1.0) * r;
}

fn main() -> void {
    val edges: f64[22] = { 0.0, -0.0, 1.0, -1.0, 0.5, -0.5, 2.0, 10.0, 1e-310, -1e-310, 5e-324, 1.7976931348623157e308, -1.7976931348623157e308, 2.2250738585072014e-308, 3.141592653589793, 1.5707963267948966, 710.0, -745.5, 1e22, 1e300, 1.0 / 0.0, -1.0 / 0.0 };
    val nan = 0.0 / 0.0;
    for (f) in 0..@cast<usize>(25) {
        for (a) in edges {
            for (b) in edges {
                run(f, a, b);
            }
            run(f, a, nan);
            run(f, nan, a);
        }
        for (i) in 0..12000 {
            run(f, any(), any());
            run(f, within(1.0), within(1.0));
            run(f, within(10.0), within(10.0));
            run(f, within(1000.0), within(30.0));
            run(f, within(1e-6), within(1e6));
            run(f, within(1e22), within(1e3));
        }
    }
    for (i) in 0..40000 {
        val x = @cast<f32>(within(100.0));
        val y = @cast<f32>(within(4.0));
        val a = @cast<f32>(any());
        same32("sinf", x, sinf(x), std::math::portable::sin(x), false);
        same32("expf", x, expf(x), std::math::portable::exp(x), false);
        same32("logf", x, logf(x), std::math::portable::log(x), false);
        same32("powf", x, powf(x, y), std::math::portable::pow(x, y), false);
        same32("sqrtf", a, sqrtf(a), std::math::portable::sqrt(a), true);
        same32("atan2f", x, atan2f(y, x), std::math::portable::atan2(y, x), false);
        same32("fmodf", a, fmodf(a, x), std::math::portable::fmod(a, x), true);
        same32("floorf", a, floorf(a), std::math::portable::floor(a), true);
    }
    std::println("f32 bad {}", bad32);
    var total: u64 = bad32;
    for (f) in 0..@cast<usize>(25) {
        if (bad[f] > 0) {
            std::println("{} worst {} ulps, {} over in {}", NAMES[f], worst[f], bad[f], count[f]);
        }
        total += bad[f];
    }
    std::println("bad {}", total);
}
// expect: f32 bad 0
// expect: bad 0
