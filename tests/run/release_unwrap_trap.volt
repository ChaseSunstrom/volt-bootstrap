// a release build checks .value unwraps an optional that holds one, as one compare and a trap
// instruction (132: SIGILL on x86-64, 133: SIGTRAP on arm64)
use std::io;
fn find(xs: i32[..], want: i32) -> usize? {
    for (x, i) in xs {
        if (x == want) {
            return i;
        }
    }
    return null;
}
fn main() -> void {
    val a: i32[3] = { 4, 5, 6 };
    if (find(a[0..3], 5).value != 1) {
        std::process::exit(3);
    }
    std::println(find(a[0..3], 9).value);
}
// flags: --release
// exit: 132|133
