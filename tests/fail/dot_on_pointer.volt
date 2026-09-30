struct s { x: i32; }
fn main() -> void { var v: s = { x: 1 }; val p: s* = &v; val y = p.x; }
// error: reach what it points at with ->
