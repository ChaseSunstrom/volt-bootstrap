// @bitcast<T>(x): the same bits read as another type of the same size
use std::io;

struct pair { a: u32; b: u32; }

fn main() -> void {
    val one = @bitcast<u64>(1.0);
    std::println("{:x} {:x} {}", one, @bitcast<u32>(@cast<f32>(-2.0)), @bitcast<f64>(0x4009_21FB_5444_2D18));
    // negative zero and NaN keep their bits
    std::println("{:x} {}", @bitcast<u64>(-0.0), (@bitcast<u64>(0.0 / 0.0) >> 52) & 0x7FF);
    // ints of one size keep their bits; a struct of two u32s is a u64
    val minus: i64 = -1;
    std::println("{} {}", @bitcast<u64>(minus), @bitcast<i8>(@cast<u8>(200)));
    val p: pair = { a: 1, b: 2 };
    std::println("{:x}", @bitcast<u64>(p));
    // round trip
    val x = 6.02214076e23;
    std::println("{}", @bitcast<f64>(@bitcast<u64>(x)) == x);
}
// expect: 3ff0000000000000 c0000000 3.141592653589793
// expect: 8000000000000000 2047
// expect: 18446744073709551615 -56
// expect: 200000001
// expect: true
