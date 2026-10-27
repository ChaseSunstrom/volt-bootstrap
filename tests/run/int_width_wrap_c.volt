// flags: --release --backend c
// a release build wraps an odd-width integer at its width, as the standard integers wrap at theirs
use std::io;

fn main() -> void {
    var x: u24 = 16777215;
    x += 1;
    var y: i7 = 63;
    y += 1;
    std::println("{} {}", x, y);
}
// expect: 0 -64
