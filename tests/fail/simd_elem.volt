use std::simd;
fn main() -> void {
    val a: std::simd::vec(bool, 4) = { true, false, true, false };
}
// error: a vector's lanes are numbers, not bool
