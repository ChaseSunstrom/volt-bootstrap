use std::io;
use std::simd;
// --release: a vector shift takes each lane's amount modulo the width, as a scalar shift does
// flags: --release
fn main() -> void {
    val s: std::simd::i32x4 = { 1, -8, 256, -1 };
    val l = s << 33;
    val r = s >> std::simd::splat<std::simd::i32x4>(33);
    std::println("{} {} {} {}", l[0], l[1], l[2], l[3]);
    std::println("{} {} {} {}", r[0], r[1], r[2], r[3]);
}
// expect: 2 -16 512 -2
// expect: 0 -4 128 -1
