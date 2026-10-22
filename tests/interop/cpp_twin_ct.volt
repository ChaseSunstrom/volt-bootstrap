// a declared class template's method templates: called per use (clang works each call out)
use std::io;
use { "cpp_twin_ct.hpp" } as cpp;

fn main() -> void {
    var a: cpp::twc::Bag<i32> = { base: 7 };
    std::println("bag {} {} {} {}", a.plain(1), a.one(2), a.one(2.5), a.cast_to<f64>());
    std::println("sz {} {}", cpp::twc::Bag<i32>::sz(1.5), cpp::twc::Bag<i32>::sz(@cast<i16>(1)));
}
// expect: bag 8 9 9 7
// expect: sz 8 2
