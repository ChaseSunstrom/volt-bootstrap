// @field names a field like v.name does: a name the struct doesn't have is an error
struct point {
    x: i32;
}

fn main() -> void {
    val p: point = { x: 1 };
    val a = @field(p, "z");
}
// error: point has no field 'z'
