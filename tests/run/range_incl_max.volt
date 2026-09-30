// lo..=hi as a stored value keeps an exclusive end (hi + 1); when hi is its type's maximum that
// overflows, which traps in debug builds instead of making an empty range. A for loop over the
// range written in place has no stored end and runs to the maximum.
use std::io;

fn main() -> void {
    val hi: u8 = 255;
    val lo: u8 = 250;
    var n = 0;
    for (i) in lo..=hi {
        n += 1;
    }
    std::println(n);
    val r = lo..=hi;
    std::println("unreachable {}", r);
}
// expect: 6
// exit: 101
