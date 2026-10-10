use std::simd;
fn main() -> void {
    val a: std::simd::vec(f64, 3) = { 1.0, 2.0, 3.0 };
}
// error: a vector has 2, 4, 8, 16, 32 or 64 lanes of at most 64 bytes in all, not 3 f64s
