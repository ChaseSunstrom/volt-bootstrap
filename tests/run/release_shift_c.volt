// release: a shift by at least the width shifts by the amount modulo the width (c backend; it was
// undefined in both backends' output, and LLVM's printed nothing)
use std::io;
fn main() -> void {
    var x: u64 = 1024;
    var s: u32 = 70;
    var y: i32 = 3;
    var t: u8 = 33;
    std::println("{} {} {} {}", x >> s, y << t, x << 64, @cast<u8>(255) >> s);
}
// flags: --release --backend c
// expect: 16 6 1024 3
