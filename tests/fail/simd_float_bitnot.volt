use std::simd;
// ~ flips an int vector's bits; a float vector has none to flip, at run time as at comptime
fn main() -> void {
    val f: std::simd::f32x4 = { 1.0, 2.0, 3.0, 4.0 };
    val g = ~f;
}
// error: ~ needs an integer, found
