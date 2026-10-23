// cpp_array_ref98.hpp's arrays, run under C++98 (--cc -std=c++98) as under the newest standard: a
// class held by handle and std::strings copied in through a std::vector (whose push_back assigns
// before C++11), a non-const array's changes copied back
use std::io;
use { "cpp_array_ref98.hpp" } as cpp;
fn main() -> void {
    var bs: cpp::ar98::Box[2] = { cpp::ar98::Box::new("a", 1), cpp::ar98::Box::new("b", 2) };
    std::println("total {}", cpp::ar98::total(&bs));
    cpp::ar98::grow(&bs, 10);
    std::println("grow {} {}", bs[0].get(), cpp::ar98::total(&bs));
    var ss: std::string[2] = { std::string::from("ab"), std::string::from("c") };
    cpp::ar98::append(&ss, "x");
    val vs: str[2] = { ss[0].as_str(), ss[1].as_str() };
    std::println("strings {} {} {}", ss[0].as_str(), ss[1].as_str(), cpp::ar98::lengths(vs));
}
