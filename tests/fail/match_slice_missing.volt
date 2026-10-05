// a match over a slice has to cover every length
use std::io;
fn f(xs: i32[..]) -> void {
    match (xs) {
        [] => std::println("none"),
        [x] => std::println("one"),
    }
}
fn main() -> void {}
// error: match doesn't handle a slice of length 2 (add arms or a default)
