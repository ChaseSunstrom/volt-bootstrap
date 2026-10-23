// a Volt string given to two std::string& parameters is one C++ string: both writes land, in C++'s
// order; two strings each get their own
use std::io;
use { "cpp_string_twice.hpp" } as cpp;
fn main() -> void {
    var s = std::string::from("s");
    cpp::st::both(&s, &s);
    var a = std::string::from("a");
    var b = std::string::from("b");
    cpp::st::both(&a, &b);
    std::println("{} {} {}", s, a, b);
    var t = std::string::from("t");
    var u = std::string::from("u");
    val n = cpp::st::three(&t, 10, &u, &t);
    std::println("{} {} {}", t, u, n);
}
