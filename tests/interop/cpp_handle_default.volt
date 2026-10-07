// a C++ class Volt holds by handle is never empty: {} makes it as C++'s T{} would (a class that
// can't be made from nothing makes {} a compile error: cpp_handle_no_default.volt)
use std::io;
use { "handles_default.hpp" } as cpp;

struct pair {
    left: cpp::h::named = {};
    count: i32 = 2;
}

fn main() -> void {
    val a: cpp::h::named = {};
    val p: pair = {};
    val b = cpp::h::only::new("given");
    std::println("{} {} {} {}", a.name(), p.left.name(), p.count, b.name());
}
