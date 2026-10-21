// val_cpp_write_both through a string hole's own method: {0}.clear() changes the string (a call with
// no arguments, its object still written), a write through s, so lending it a val is an error naming both
use std::io;
use { "val_cpp_write.hpp" } as cpp;

fn g(s: std::string&) -> void {
    @cpp<void, std::string>("{0}.clear()", s);
}

fn main() -> void {
    val k = std::string::from("hi");
    g(&k);
    std::print("{}", k);
}
// error: 'k' is a val, and g changes it (through s): declare it with var
