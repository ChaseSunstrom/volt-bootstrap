// a call worked out per use returning a struct that holds a pointer into the copy of a std::string&
// Volt made for it is an error, as a view is (that copy is gone once the call returns)
use std::io;
use { "params.hpp" } as cpp;
fn main() -> void {
    var t = std::string::from("two words");
    val w: cpp::pr::word_at = @cpp("pr::first_at({0})", &t);
    std::println("{}", w.n);
}
