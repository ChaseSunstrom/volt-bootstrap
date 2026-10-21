// val_cpp_write_both through a member operator: C++ counts rd() as the call's first argument, so
// the string is its second, matched to operator>>'s std::string& (a write through s)
use std::io;
use { "val_cpp_write.hpp" } as cpp;

fn g(s: std::string&) -> void {
    @cpp<void, std::string>("vw::rd() >> {0}", s);
}

fn main() -> void {
    val k = std::string::from("hi");
    g(&k);
    std::print("{}", k);
}
// error: 'k' is a val, and g changes it (through s): declare it with var
