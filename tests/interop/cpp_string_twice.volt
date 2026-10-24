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
    // a const std::string& given the same string: that string (a std::string with the same text
    // isn't it)
    var v = std::string::from("hi");
    val r1 = cpp::st::seen(&v, v.as_str());
    var w = std::string::from("yo");
    val r2 = cpp::st::seen2(w.as_str(), &w);
    var x = std::string::from("hi");
    val y = std::string::from("hi");
    val r3 = cpp::st::seen(&x, y.as_str());
    std::println("{} {} {} {} {} {}", r1, v, r2, w, r3, x);
}
