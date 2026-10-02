// a value that's computed and dropped
struct point {
    x: i32;
    y: i32;
}

fn main() -> void {
    val p: point = { x: 1, y: 2 };
    p.x * 2 + p.y;
}
// error: this value is never used
