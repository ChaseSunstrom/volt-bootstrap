// f128 % is exact (C's fmod): x - trunc(x / y) * y, which is always a binary128 itself. The
// expected bits come from Python's Fractions, independent of std::softfloat:
//   x, y = exact rationals of the bits; r = x - trunc(x / y) * y; bits(r), -0 for a negative x
// (the inputs are bits: an f128 literal is only an f64's precision until T-0477)
use std::io;

fn q(b: u128) -> f128 { return @bitcast<f128>(b); }
fn bits(x: f128) -> u128 { return @bitcast<u128>(x); }

fn main() -> void {
    // integers, a negative x, max finite, subnormals, the widest exponent gap
    std::println("{}", bits(q(0x40630000000000000000000000003000) % q(0x4001C000000000000000000000000000)));
    std::println("{}", bits(q(0x40630000000000000000000000003000) % q(0x40415AF1D78B58C40000000000000000)));
    std::println("{}", bits(q(0xC0630000000000000000000000003000) % q(0x4001C000000000000000000000000000)));
    std::println("{}", bits(q(0x7FFEFFFFFFFFFFFFFFFFFFFFFFFFFFFF) % q(0x3FFB999999999999999999999999999A)));
    std::println("{}", bits(q(0x7FFE8000000000000000000000000000) % q(0x00000000000000000000000000000007)));
    std::println("{}", bits(q(0x4000921FB54442D18469898CC51701B8) % q(0x3FFE0000000000000000000000000001)));
    std::println("{}", bits(q(0x00000000000000000000000123456789) % q(0x000000000000000000000000000000FF)));
    std::println("{}", bits(q(0x3FFF0000000000000000000000000001) % q(0x3FFF0000000000000000000000000000)));
    std::println("{}", bits(q(0x3FFF0000000000000000000000000000) % q(0x40008000000000000000000000000000)));
    std::println("{}", bits(q(0x7FFEFFFFFFFFFFFFFFFFFFFFFFFFFFFF) % q(0x00000000000000000000000000000001)));
    // specials, as C's fmod: -4 % 2 is -0, x % 0 and inf % y NaN, x % inf x, a NaN stays one
    val m4: f128 = -4;
    val two: f128 = 2;
    val zero: f128 = 0;
    val inf = q(0x7FFF0000000000000000000000000000);
    val nan = q(0x7FFF8000000000000000000000000000);
    std::println("{} {} {} {}", bits(m4 % two) >> 127, bits(m4 % two) << 1, (two % zero) != (two % zero), (inf % two) != (inf % two));
    std::println("{} {}", @cast<f64>(two % inf), (nan % two) != (nan % two));
    // the widest gap, many times: each is a bounded loop (about 2200 steps), not one per bit
    var acc: u128 = 0;
    for (i) in 0..1000 {
        acc |= bits(q(0x7FFEFFFFFFFFFFFFFFFFFFFFFFFFFFFF) % q(0x0000000000000000000000000000000B));
    }
    std::println("{}", acc);
}
// expect: 85077082101307784400379314978353577984
// expect: 85400460005592615471175760839379517440
// expect: 255218265561777016132066618694237683712
// expect: 84907034379190768795544941223571619840
// expect: 5
// expect: 85050511774665348875829607353696656232
// expect: 90
// expect: 84483862185220180343819705772740182016
// expect: 85065399433376081038215121361612832768
// expect: 0
// expect: 1 0 true true
// expect: 2 true
// expect: 4
