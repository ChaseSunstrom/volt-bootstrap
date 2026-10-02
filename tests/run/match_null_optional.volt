// match's null pattern on optionals that aren't pointers underneath (T-0175)
use std::io;

fn show(x: i32?) -> void {
    match (x) {
        null => { std::println("none"); },
        default => { std::println("some {}", x); },
    }
}

struct point { x: i32; y: i32; }

fn where(p: point?) -> str {
    match (p) {
        null => { return "nowhere"; },
        default => { return "somewhere"; },
    }
}

fn main() -> void {
    show(3);
    show(null);
    val b: std::mem::box<i32>? = i32::new(5) catch @panic("oom");
    match (b) {
        null => { std::println("no box"); },
        default => { std::println("a box"); },
    }
    val origin: point = { x: 0, y: 0 };
    std::println("{} {}", where(origin), where(null));
}
// expect: some 3
// expect: none
// expect: a box
// expect: somewhere nowhere
