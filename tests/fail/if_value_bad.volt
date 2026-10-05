// if values that don't check
use std::io;

fn pick(c: bool) -> i32 {
    return if (c) 1 else "one";
}

fn count(n: i32) -> i32 {
    return if (n) 1 else 2;
}

fn main() -> void {
    val a = pick(true) + count(3);
    val b = if (a > 1) 2 else {
        std::println("no value");
    };
}

fn say(a: i32) -> void {
    if (a > 1) std::println("big") else std::println("small");
}
// error: expected i32, found str
// error: expected bool, found i32
// error: an arm of this if is a block with no value: a block arm has to leave (return, break, @panic ...)
// error: an if without { } is a value, and this arm has none; an if statement takes braces
