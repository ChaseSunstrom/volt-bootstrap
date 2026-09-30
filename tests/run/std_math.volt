use std::io;
use std::math;
// std::math: constants, libm in f64 and f32, float classes, abs/min/max/clamp, integer limits,
// checked and saturating arithmetic at the overflow edges, gcd and lcm

fn main() -> void {
    // constants
    std::println("{:.5} {:.5} {:.5} {:.5} {:.5} {:.5} {}", std::PI, std::TAU, std::E, std::SQRT2, std::LN2, std::LN10, 1.0 + std::EPSILON != 1.0 && 1.0 + std::EPSILON / 2.0 == 1.0);

    // libm, f64
    std::println("{:.4} {:.4} {:.4} {:.4} {:.4} {:.4} {:.4} {:.4}", std::sqrt(2.0), std::cbrt(27.0), std::pow(2.0, 10.0), std::exp(1.0), std::exp2(3.0), std::log(std::E), std::log2(8.0), std::log10(1000.0));
    std::println("{:.4} {:.4} {:.4} {:.4} {:.4} {:.4} {:.4}", std::sin(std::PI / 2.0), std::cos(std::PI), std::tan(std::PI / 4.0), std::asin(1.0), std::acos(0.0), std::atan(1.0), std::atan2(1.0, -1.0));
    std::println("{:.4} {:.4} {:.4} {:.4}", std::sinh(1.0), std::cosh(1.0), std::tanh(1.0), std::hypot(3.0, 4.0));
    std::println("{} {} {} {} {} {}", std::floor(-2.5), std::ceil(-2.5), std::round(-2.5), std::round(2.5), std::trunc(-2.7), std::fmod(7.5, 2.0));

    // libm, f32: the f32 overloads return f32
    val x: f32 = 2.0;
    val r: f32 = std::sqrt(x);
    val p: f32 = std::pow(x, x);
    val t: f32 = std::sin(x) + std::cos(x) + std::tan(x) + std::exp(x) + std::log(x) + std::floor(x) + std::abs(x);
    std::println("{:.4} {} {:.4}", r, p, t);

    // classification and the special values
    val nan = std::NAN;
    std::println("{} {} {} {} {} {} {} {}", std::is_nan(nan), std::is_nan(1.0), std::is_inf(std::INF), std::is_inf(-std::INF), std::is_inf(1.0), std::is_finite(1.0), std::is_finite(std::INF), std::is_finite(nan));
    std::println("{} {} {}", std::INF, -std::INF, nan);

    // abs, min, max, clamp
    std::println("{} {} {} {} {} {} {} {} {}", std::abs(-5), std::abs(-2.5), std::abs(-0.0), std::min(3, 7), std::max(3, 7), std::min(1.5, -1.5), std::clamp(15, 0, 10), std::clamp(-3, 0, 10), std::clamp(5, 0, 10));

    // integer limits
    std::println("{} {} {} {} {} {}", i8::min_value(), i8::max_value(), u8::min_value(), u8::max_value(), i16::min_value(), u16::max_value());
    std::println("{} {} {} {} {}", i32::min_value(), i32::max_value(), u32::max_value(), i64::min_value(), u64::max_value());
    std::println("{} {} {} {}", i128::min_value(), u128::max_value(), isize::max_value(), usize::max_value());

    // checked: null on overflow
    val a: i8 = 100;
    val na: i8 = -100;
    val three: u8 = 3;
    val five: u8 = 5;
    std::println("{} {} {} {}", std::checked_add(a, 27), std::checked_add(a, 28), std::checked_add(na, -28), std::checked_add(na, -29));
    std::println("{} {} {} {} {}", std::checked_sub(three, five), std::checked_sub(five, three), std::checked_sub(na, 28), std::checked_sub(na, 29), std::checked_sub(0 as i8, i8::min_value()));
    val big: i32 = 65536;
    val min32 = i32::min_value();
    val sixteen: u8 = 16;
    val shift: u64 = 4294967296;
    std::println("{} {} {} {} {} {} {} {}", std::checked_mul(big, 32768), std::checked_mul(-big, 32768), std::checked_mul(min32, -1), std::checked_mul(-1, min32), std::checked_mul(shift, shift), std::checked_mul(sixteen, 15), std::checked_mul(sixteen, 16), std::checked_mul(0, min32));
    std::println("{} {} {} {}", std::checked_div(7, 0), std::checked_div(min32, -1), std::checked_div(-7, 2), std::checked_div(min32, 1));

    // saturating: clamped to the type's range
    val two_hundred: u8 = 200;
    val twenty: u8 = 20;
    val ten: i8 = 10;
    std::println("{} {} {} {} {}", std::saturating_add(a, 100), std::saturating_add(na, -100), std::saturating_add(two_hundred, 100), std::saturating_sub(three, five), std::saturating_sub(na, 100));
    std::println("{} {} {} {}", std::saturating_mul(na, 2), std::saturating_mul(na, -2), std::saturating_mul(twenty, 20), std::saturating_mul(ten, 10));

    // gcd and lcm
    std::println("{} {} {} {} {} {} {}", std::gcd(48, 18), std::gcd(-48, 18), std::gcd(0, 5), std::gcd(0, 0), std::lcm(4, 6), std::lcm(-4, 6), std::lcm(0, 6));
}
// expect: 3.14159 6.28319 2.71828 1.41421 0.69315 2.30259 true
// expect: 1.4142 3.0000 1024.0000 2.7183 8.0000 1.0000 3.0000 3.0000
// expect: 1.0000 -1.0000 1.0000 1.5708 1.5708 0.7854 2.3562
// expect: 1.1752 1.5431 0.7616 5.0000
// expect: -3 -2 -3 3 -2 1.5
// expect: 1.4142 4 10.3903
// expect: true false true true false true false false
// expect: inf -inf nan
// expect: 5 2.5 0 3 7 -1.5 10 0 5
// expect: -128 127 0 255 -32768 65535
// expect: -2147483648 2147483647 4294967295 -9223372036854775808 18446744073709551615
// expect: -170141183460469231731687303715884105728 340282366920938463463374607431768211455 9223372036854775807 18446744073709551615
// expect: 127 null -128 null
// expect: null 2 -128 null null
// expect: null -2147483648 null null null 240 null 0
// expect: null null -3 -2147483648
// expect: 127 -128 255 0 -128
// expect: -128 127 255 100
// expect: 6 6 5 0 12 12 0
