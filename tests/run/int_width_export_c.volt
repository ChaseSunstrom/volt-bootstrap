// flags: --backend c
// an export fn taking an odd width: a caller from outside Volt passes its storage size, and a value
// out of the width's range stops the program at the call
use std::io;

export fn low24(x: u24) -> u32 {
    return x;
}

fn main() -> void {
    val as_c = @cast<extern "C" fn(u32) -> u32>(low24);
    std::println("{}", as_c(16777215));
    std::println("{}", as_c(16777216));
}
// expect: 16777215
// exit: 101
// expect-stderr: argument 'x' is out of u24's range
