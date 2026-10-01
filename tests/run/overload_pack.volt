use std::io;
// a pack of bare generics (xs: T...) is as blanket as a bare T: a version for a type wins over it
struct meters { v: f64; }
<T: type...>
fn describe(first: meters, rest: T...) -> str { return "meters first"; }
<F: type, T: type...>
fn describe(first: F, rest: T...) -> str { return "anything"; }
fn main() -> void {
    val m: meters = { v: 1.0 };
    std::println("{} {}", describe(m, 1, 2), describe(3, 4));
}
// expect: meters first anything
