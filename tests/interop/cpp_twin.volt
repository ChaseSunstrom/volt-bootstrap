// a template pair f(T&) / f(T): f(&m) calls the reference one, f_value(5) the value one
use std::io;
use { "cpp_twin.hpp" } as cpp;

fn main() -> void {
    var m: i32 = 5;
    val r = cpp::tw::twin(&m);
    std::println("ref {} {}", r, m);
    std::println("value {}", cpp::tw::twin_value(5));
    val k: i32 = 3;
    std::println("peek {} {}", cpp::tw::peek(&k), cpp::tw::peek_value(4));
    val p: i32* = &m;
    std::println("deref {} {}", cpp::tw::deref(&p), cpp::tw::deref_value(p));
}
// expect: ref 1 6
// expect: value 2
// expect: peek 13 24
// expect: deref 36 46
