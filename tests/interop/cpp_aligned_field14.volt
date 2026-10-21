// below C++17 (run with --cc -std=c++14): the classes aligned to 8 or less are still handles (C++'s
// plain new), and af::cell, aligned to 16, is left out (no aligned new)
use std::io;
use { "cpp_aligned_field.hpp" } as cpp;

fn main() -> void {
    var t: cpp::af::tight = {};
    t.set_x(9);
    var m: cpp::af::mixed = {};
    m.set_x(11);
    std::println("c++14 {} {}", cpp::af::tight_x(&t), cpp::af::mixed_x(&m));
}
