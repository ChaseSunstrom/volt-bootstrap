use std::io;
// locals named like C macros (gnu11's linux, libc's stderr, a capitalised EOF), like an extern
// fn, or like the name another local is renamed to, still get C names of their own
extern "C" fn abs(x: i32) -> i32;
fn main() -> void {
    var linux: i32 = 1;
    var stderr: i32 = 2;
    var abs: i32 = abs(-3);
    var EOF: i32 = 4;
    var x_5: i32 = 5;
    var x: i32 = 6;
    {
        var x: i32 = 7;
        x_5 += x;
    }
    std::println("{} {} {} {} {} {}", linux, stderr, abs, EOF, x_5, x);
}
// expect: 1 2 3 4 12 6
