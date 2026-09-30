struct p { x: i32; y: i32; }
fn main() -> void { val a: p = { x: 1 }; }
// error: missing field 'y'
