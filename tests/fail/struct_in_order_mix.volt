struct pt { x: i32; y: i32; }

fn main() -> void {
    val y = 1;
    val p: pt = { y, 2 };
}
// error: 'y' names pt's field y, and sits in x's place
