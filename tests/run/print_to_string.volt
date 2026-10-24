// a struct attaching to_string(this: T&) giving a string prints that string, deleted after
use std::io;
use std::fmt;

struct pt {
    x: i32;
}

attach fn to_string(this: pt&) -> std::string {
    return std::format("pt({})", this.x);
}

fn main() -> void {
    val p: pt = { x: 3 };
    std::println("{} and {}", p, p.x);
}

// flags: --leak-check
// expect: pt(3) and 3
