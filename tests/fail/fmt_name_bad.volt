// what goes between the braces is a name, a path or a field path
use std::io;
fn main() -> void {
    val x = 1;
    std::println("{x.}");
}
// error: a name in a format string is a path like {x}, {a::B} or {p.x}
