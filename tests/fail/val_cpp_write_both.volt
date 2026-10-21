// a Volt fn passing its reference parameter to a C++ template with S& and const S& overloads
// through @cpp, S deduced: C++ runs S& (the string can change), a write through the parameter, so
// lending it a val is an error naming both (val_cpp_write_try: the catching form)
use std::io;
use { "val_cpp_write.hpp" } as cpp;

fn g(s: std::string&) -> i32 {
    return @cpp<i32, std::string>("vw::pick({0})", s);
}

fn main() -> void {
    val k = std::string::from("hi");
    std::print("{}", g(&k));
}
// error: 'k' is a val, and g changes it (through s): declare it with var
