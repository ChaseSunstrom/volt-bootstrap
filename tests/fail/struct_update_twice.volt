// a struct update sets a field twice
struct pt { x: i32; y: i32; }
fn main() -> void { val p: pt = { x: 1, y: 2 }; val q: pt = { ..p, x: 3, x: 4 }; }
// error: field 'x' is set twice
