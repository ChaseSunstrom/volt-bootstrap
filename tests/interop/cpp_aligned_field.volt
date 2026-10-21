// classes with a field of an aligned typedef: Volt's own layout of the field's int isn't C++'s, so
// they're held by handle (C++ lays them out), and a field written in Volt reads back in C++
use std::io;
use { "cpp_aligned_field.hpp" } as cpp;

fn main() -> void {
    var a: cpp::af::cell = {};
    a.set_x(7);
    val b = copy a;
    std::println("cell {} {} {} {}", cpp::af::cell_x(b), a.aligned(), b.aligned(), cpp::af::cell_size());
    var t: cpp::af::tight = {};
    t.set_x(9);
    std::println("tight {} {}", cpp::af::tight_x(t), cpp::af::tight_size());
    var m: cpp::af::mixed = {};
    m.set_x(11);
    m.set_d(0.5);
    std::println("mixed {} {} {}", cpp::af::mixed_x(m), m.d(), cpp::af::mixed_size());
}
