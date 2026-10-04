// a debug build checks a variant's payload is read from a value holding that variant
use std::io;

enum shape {
    CIRCLE: i32,
    SQUARE: i32,
}

fn main() -> void {
    val s = shape::SQUARE(3);
    std::println("{}", s.SQUARE);
    std::println("{}", s.CIRCLE);
}
// expect: 3
// exit: 101
// expect-stderr: reading CIRCLE's payload, but the value is another variant
