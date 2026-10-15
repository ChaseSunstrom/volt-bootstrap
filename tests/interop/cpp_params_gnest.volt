// a Volt std::string crosses a C++ template only as its parameter S (S, S&, const S&): S nested in
// another type (S*, std::vector<S>) or as the result is an error, each call
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
