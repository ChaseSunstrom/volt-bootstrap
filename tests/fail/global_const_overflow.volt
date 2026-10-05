// a constant expression that a global's type can't hold
use std::io;
val X: u8 = 1 << 9;
fn main() -> void {
    std::println("{}", X);
}
// error: 512 doesn't fit in u8
