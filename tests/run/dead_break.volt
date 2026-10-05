// a break after a statement that always leaves never runs, so it doesn't make its block or loop
// one that can be left: f still returns on every path
use std::io;

fn f(k: i32) -> i32 {
    :b {
        if (k > 0) {
            return k;
        }
        return 0;
        break :b;
    }
}

fn main() -> void {
    std::println("{} {}", f(3), f(-1));
}
// expect: 3 0
