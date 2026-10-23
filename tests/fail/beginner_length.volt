// a method under another language's name: the one whose name it starts with (len)
use std::io;
fn main() -> void {
    val s = std::string::from("hi");
    std::println("{}", s.length());
}
// error: has no method 'length'
// error: did you mean 'len'?
