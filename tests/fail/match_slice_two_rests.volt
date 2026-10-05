// a slice pattern has one .. at most
fn f(xs: i32[..]) -> void {
    match (xs) {
        [.., x, ..] => {},
        default => {},
    }
}
fn main() -> void {}
// error: a slice pattern has one .. at most
