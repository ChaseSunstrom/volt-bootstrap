// classes with a field of an aligned typedef: Volt's own layout of the field's int isn't C++'s, so
// they're held by handle (C++ lays them out), and a field written in Volt reads back in C++
use std::io;
use { "cpp_aligned_field.hpp" } as cpp;

fn main() -> void {
    var a: cpp::af::cell = {};
    a.set_x(7);
    val b = copy a;
    std::println("cell {} {} {} {} {}", b.read_x(), cpp::af::cell_x(&b), a.aligned(), b.aligned(), cpp::af::cell_size());
    var t: cpp::af::tight = {};
    t.set_x(9);
    std::println("tight {} {}", cpp::af::tight_x(&t), cpp::af::tight_size());
    var m: cpp::af::mixed = {};
    m.set_x(11);
    m.set_d(0.5);
    std::println("mixed {} {}", cpp::af::mixed_x(&m), m.d());
    var s: cpp::af::squeezed = {};
    s.set_x(13);
    std::println("squeezed {} {}", cpp::af::squeezed_x(&s), cpp::af::squeezed_size());
    var tc: cpp::af::tcell<i8> = {};
    tc.set_x(5);
    var tw: cpp::af::twide<i32> = {};
    tw.set_x(2);
    std::println("templates {} {}", cpp::af::tcell_x(&tc), cpp::af::twide_x(&tw));
}
