// a release build checks .value unwraps an error union that holds a value, as one compare and a
// trap instruction (132: SIGILL on x86-64, 133: SIGTRAP on arm64)
use std::io;
error bad { NEGATIVE }
fn half(n: i32) -> bad!i32 {
    if (n < 0) {
        return bad::NEGATIVE;
    }
    return n / 2;
}
fn main() -> void {
    if (half(8).value != 4) {
        std::process::exit(3);
    }
    std::println(half(-2).value);
}
// flags: --release
// exit: 132|133
