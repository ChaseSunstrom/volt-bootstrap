comptime fn big() -> i8 { var x: i8 = 100; x += 100; return x; }
fn main() -> void { val y = big(); }
// error: overflow
