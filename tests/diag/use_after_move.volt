// a use after a move points back at the move
use std::io;

fn eat(s: std::string) -> void {}

fn main() -> void {
    val s = std::string::from("hi");
    eat(s);
    std::println("{}", s);
}
