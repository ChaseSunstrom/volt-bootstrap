use std::io;
fn main() -> i32 {
    var x: u8 = 250;
    x = x +% 10;
    std::println(x);
    var y: i8 = 127;
    y += 1;
    std::println("unreachable");
    return 0;
}
// expect: 4
// exit: 101
