// @bitcast between types of different sizes
fn main() -> void { val b = @bitcast<u32>(1.5); }
// error: @bitcast needs types of one size: f64 is 8 bytes, u32 is 4
