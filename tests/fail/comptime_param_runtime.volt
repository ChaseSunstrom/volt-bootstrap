fn f(comptime n: i32) -> void {}
fn main() -> void { var k = 3; f(k); }
// error: must be known at compile time
