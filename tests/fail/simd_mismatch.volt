use std::simd;
fn main() -> void {
    val a: std::simd::f64x2 = { 1.0, 2.0 };
    val b: std::simd::f32x4 = { 1.0, 2.0, 3.0, 4.0 };
    val c = a + b;
}
// error: + needs two values of one vector type: @vector(f64, 2) and @vector(f32, 4)
