struct pt { x: i32; y: i32; }

fn main() -> void {
    val p: pt = { 1, 2, 3 };
}
// error: pt has 2 fields, and this literal gives more
