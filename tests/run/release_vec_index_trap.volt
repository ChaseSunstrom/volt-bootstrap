// a release build keeps std::vec's bounds check: v[i] past the end traps (132 SIGILL on x86-64,
// 133 SIGTRAP on arm64) instead of reading what's past the elements
use std::io;
fn main() -> void {
    var v: std::vec<i32> = {};
    v.push(1) catch @panic("out of memory");
    if (v[0] != 1) {
        std::process::exit(3);
    }
    std::println(v[4]);
}
// flags: --release
// exit: 132|133
