// in a comptime match, a bare name that is one of the enum's variants tests for that variant (as a
// runtime match does) instead of binding the value
use std::io;

enum k { A, B }
enum shape { DOT, LINE: i32 }

fn main() -> void {
    comptime val x = comptime match (k::B) {
        A => 1,
        default => 2,
    };
    comptime val y = comptime match (shape::LINE(3)) {
        DOT => 0,
        .LINE(n) => n,
    };
    comptime val z = comptime match (k::A) {
        A => 10,
        other => 20,
    };
    std::println("{} {} {}", x, y, z);
}
// expect: 2 3 10
