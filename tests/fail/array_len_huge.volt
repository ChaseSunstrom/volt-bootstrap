// error: is too big
struct S { x: i32[1 << 100]; }
fn main() -> void { var s: S; }
