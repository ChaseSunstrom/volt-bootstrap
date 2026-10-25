// a slice of Volt std::strings for a C++ template's std::vector<S> is an error (a str[..] of their
// text crosses: cpp_params.volt); S* and S as the result cross
use std::io;
use { "params.hpp" } as cpp;
fn main() -> void {
    var t = std::string::from("a");
    val p: std::string* = &t;
    std::println("{}", cpp::pr::gs::deref(p));
    val e = cpp::pr::gs::echo(&t);
    var ts: std::string[1] = { std::string::from("b") };
    std::println("{}", cpp::pr::gs::count_all(ts[..]));
}
