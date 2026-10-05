// binding in if needs an optional or an error union
fn main() -> void {
    if (val n = 5) {
    }
}
// error: if (val ...) needs an optional or an error union, found i32
