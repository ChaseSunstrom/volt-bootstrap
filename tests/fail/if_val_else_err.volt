// else |err| needs an error union
fn half(x: i32) -> i32? { return x / 2; }
fn main() -> void {
    if (val h = half(4)) {
    } else |e| {
    }
}
// error: else |e| needs an error union, found i32?
