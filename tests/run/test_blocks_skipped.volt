// an ordinary build leaves test blocks out entirely: they aren't even checked
use std::io;

fn main() -> void {
    std::println("main runs");
}

test "not built" {
    val x: i32 = "a string";
    no_such_function();
}
// expect: main runs
