// a field path in a format string is checked like any field
use std::io;
struct point { x: i32; }
fn main() -> void {
    val p: point = { x: 1 };
    std::println("{p.z}");
}
// error: no field 'z'
