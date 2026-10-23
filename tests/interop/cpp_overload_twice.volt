// Overloads that collide after their first rename too: the first free name (the words, then _2, _3),
// each calling exactly its own C++ overload
use std::io;
use { "cpp_overload_twice.hpp" } as cpp;
fn main() -> void {
    std::println("f {} {} {}", cpp::tw::f(1), cpp::tw::f_long(1), cpp::tw::f_long_2(1));
    std::println("g {} {} {}", cpp::tw::g(1), cpp::tw::g_long(1), cpp::tw::g_long_2(1));
    std::println("d {} {} {} {} {}", cpp::tw::d(1), cpp::tw::d(1, 0), cpp::tw::d_long_int(1), cpp::tw::d_long_int_2(1), cpp::tw::d_long_int_2(1, 0));
    var t: cpp::tw::Twice = {};
    std::println("m {} {} {}", t.m(1), t.m_long(1), t.m_long_2(1));
    std::println("peek {} {} {}", t.peek(), t.peek_nonconst(), t.peek_nonconst_2());
}
