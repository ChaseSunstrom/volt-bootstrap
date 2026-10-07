struct pt { x: i32; y: i32; }

fn main() -> void {
    val p: pt = { x: 1, 2 };
}
// error: a struct literal gives its fields all by name
