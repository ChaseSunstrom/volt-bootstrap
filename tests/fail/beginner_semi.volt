// a missing ';': the error is where it goes, after the line's last token, not on the next line
use std::io;
fn main() -> void {
    val x = 1
    std::println("{}", x);
}
// error: beginner_semi.volt:4:14: error: expected ';' after '1'
// flags: --message-format short
