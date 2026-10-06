// a release build checks a slice's range too: lo..hi past the end traps (132: SIGILL on x86-64,
// 133: SIGTRAP on arm64)
use std::io;
fn part(xs: i32[..], hi: usize) -> i32[..] {
    return xs[1..hi];
}
fn main() -> void {
    val a: i32[4] = { 1, 2, 3, 4 };
    if (part(a[0..4], 4).len != 3) {
        std::process::exit(3);
    }
    std::println(part(a[0..4], 7).len);
}
// flags: --release
// exit: 132|133
