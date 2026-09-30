comptime fn spin() -> i32 { loop { } }
fn main() -> void { val y = spin(); }
// error: took too long
