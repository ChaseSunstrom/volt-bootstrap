use std::io;
use std::simd;
// a vector's -v and ~v, and a shift by a { } literal amount, at comptime as at run time
fn ramp() -> std::simd::i32x4 {
    return { 1, -2, 3, 0 };
}

fn halves() -> std::simd::f32x4 {
    return { 0.5, -1.5, 2.0, 0.0 };
}

fn main() -> void {
    comptime val n = -ramp();
    comptime val b = ~ramp();
    comptime val s = ramp() << { 1, 2, 3, 4 };
    comptime val f = -halves();
    val r = ramp();
    val rs: std::simd::i32x4 = r << { 1, 2, 3, 4 };
    std::println("{} {} {} {}", n[1], b[0], s[2], f[1]);
    std::println("{} {} {}", n == -r, b == ~r, s == rs);
}
// expect: 2 -2 24 1.5
// expect: true true true
