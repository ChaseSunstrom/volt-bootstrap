use std::io;
// a debug build checks an i128 shift amount in its own width: 2^64 + 1 is too large, not 1
fn amount() -> i128 {
    return 18446744073709551617;
}

fn main() -> void {
    val x: i32 = 1;
    std::println("{}", x << amount());
}
// exit: 101
// expect-stderr: shift amount too large
