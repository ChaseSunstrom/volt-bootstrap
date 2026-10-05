// an if's binding is only in its first block
fn half(x: i32) -> i32? { return x / 2; }
fn main() -> void {
    if (val h = half(4)) {
    }
    val y = h;
}
// error: unknown name 'h'
