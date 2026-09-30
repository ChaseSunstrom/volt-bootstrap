use std::io;
fn eat(b: std::mem::box<i32>) -> i32 { return *b; }
fn pick(c: bool) -> i32 {
    val b = try_box(7);
    if (c) {
        return eat(move b); // leaves: b is still there on the other path
    }
    return *b + 1;
}
fn try_box(v: i32) -> std::mem::box<i32> { return i32::new(v) catch @panic("oom"); }
// a local named like a generic fn (free<T> in std) still compares with <
fn below(free: i32, cap: i32) -> bool { return free < cap; }
fn main() -> void {
    std::println("{} {} {}", pick(true), pick(false), below(1, 2));
}
// expect: 7 8 true
// flags: --leak-check
