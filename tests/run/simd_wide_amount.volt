use std::io;
use std::simd;
// ...and a vector shifted by such an amount
fn amount() -> u128 {
    return 18446744073709551617;
}

fn main() -> void {
    val s: std::simd::i32x4 = { 1, 2, 3, 4 };
    std::println("{}", (s << amount())[0]);
}
// exit: 101
// expect-stderr: shift amount too large
