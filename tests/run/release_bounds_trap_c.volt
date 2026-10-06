// release builds keep bounds checks, as one compare and a trap instruction (no call, no message):
// the program stops at the bad index (c backend). voltc run gives a signal as 128+N: 132 is
// SIGILL (x86-64's trap), 133 SIGTRAP (arm64's). Output still buffered is lost, as with C's abort,
// so the in-range read is checked by the exit code
use std::io;
fn at(xs: i32[..], i: usize) -> i32 {
    return xs[i];
}
fn main() -> void {
    val a: i32[4] = { 1, 2, 3, 4 };
    if (at(a[0..4], 3) != 4) {
        std::process::exit(3);
    }
    std::println(at(a[0..4], 9));
}
// flags: --release --backend c
// exit: 132|133
