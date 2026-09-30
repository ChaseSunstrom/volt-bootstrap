use std::io;
// the second foo's C name must not collide with foo_2's
fn foo_2() -> i32 { return 2; }
fn foo(x: i32) -> i32 { return x; }
fn foo(x: i32, y: i32) -> i32 { return x + y; }
fn main() -> void {
    std::println("{} {} {}", foo(1), foo(1, 2), foo_2());
}
// expect: 1 3 2
