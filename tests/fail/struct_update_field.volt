// a struct update names a field the struct doesn't have
struct pt { x: i32; y: i32; }
fn main() -> void { val p: pt = { x: 1, y: 2 }; val q: pt = { ..p, z: 3 }; }
// error: no field 'z'
