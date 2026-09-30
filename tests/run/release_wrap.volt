use std::io;
fn main() -> void {
    var y: i8 = 127;
    y += 1;
    std::println(y);
}
// flags: --release
// expect: -128
