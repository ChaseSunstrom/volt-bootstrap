// flags: --backend c
// a debug build traps when an odd-width integer overflows its width: u24 past 16777215
use std::io;

fn main() -> void {
    var x: u24 = 16777214;
    x += 1;
    std::println("{}", x);
    x += 1;
    std::println("unreachable {}", x);
}
// expect: 16777215
// exit: 101
// expect-stderr: integer overflow
