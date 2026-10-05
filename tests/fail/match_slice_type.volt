// slice patterns match slices, arrays and str
fn f(n: i32) -> void {
    match (n) {
        [x] => {},
        default => {},
    }
}
fn main() -> void {}
// error: slice pattern, but the value is a i32
