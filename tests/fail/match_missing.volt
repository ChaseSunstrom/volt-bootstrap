enum c { A, B, C }
fn f(x: c) -> i32 { return match (x) { .A => 1, .B => 2, }; }
fn main() -> void { f(c::A); }
// error: match doesn't handle C
