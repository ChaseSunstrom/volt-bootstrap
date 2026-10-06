// alternatives sit at the top of an arm, not inside a tuple or a payload
fn f(p: (i32, i32)) -> i32 {
    return match (p) {
        (0 | 1, x) => x,
        default => 0,
    };
}
fn main() -> void {}
// error: alternatives (a | b) go at the top of a match arm
