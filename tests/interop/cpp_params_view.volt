// a call worked out per use whose result would point into the copy of a std::string& Volt made
// for it is an error (that copy is gone once the call returns)
use std::io;
use { "params.hpp" } as cpp;
fn main() -> void {
    var t = std::string::from("two words");
    val w: str = @cpp("pr::first_word({0})", &t);
    std::println("{}", w);
}
