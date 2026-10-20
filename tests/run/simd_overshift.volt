use std::io;
use std::simd;
// a vector shifted by a lane amount at least its lanes' width stops a debug build, naming the lane (as
// a scalar shift does)
fn main() -> void {
    val s: std::simd::i32x4 = { 1, 2, 3, 4 };
    val by: std::simd::i32x4 = { 1, 2, 32, 3 };
    std::println("{}", (s << by)[0]);
}
// exit: 101
// expect-stderr: shift amount too large (lane 2)
