use std::simd;
// a comptime vector shift past the lanes' width is an error naming the lane, as a debug build's
// panic does
fn ramp() -> std::simd::i32x4 {
    var v: std::simd::i32x4 = {};
    v[1] = 1;
    return v;
}

fn main() -> void {
    comptime val x = ramp() << 32;
}
// error: shift amount too large (lane 0)
