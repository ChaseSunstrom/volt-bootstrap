// a Volt fn passing its reference parameter to a C++ template's S& writes through it, as a Volt
// write would: lending it a val is an error naming both (a const S& only reads: val_cpp_read)
use std::io;
use { "val_cpp_write.hpp" } as cpp;

fn g(s: std::string&) -> void {
    cpp::vw::fill(s);
}

fn n(s: std::string&) -> i32 {
    return cpp::vw::look(s);
}

fn main() -> void {
    val k = std::string::from("hi");
    std::print("{}", n(&k));
    g(&k);
}
// error: 'k' is a val, and g changes it (through s): declare it with var
