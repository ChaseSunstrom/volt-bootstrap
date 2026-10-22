// below C++17 (run with --cc -std=c++14): the classes aligned to 8 or less are still handles (C++'s
// plain new), and af::cell, aligned to 16, is left out (no aligned new)
use std::io;
use { "cpp_aligned_field.hpp" } as cpp;

fn main() -> void {
    // (Windows: value structs, as cpp_aligned_field.volt says)
    comptime if (@cfg("os", "windows")) {
        val t: cpp::af::tight = { c: 0, x: 9 };
        val m: cpp::af::mixed = { c: 0, x: 11, d: 0.5 };
        std::println("c++14 {} {}", cpp::af::tight_x(&t), cpp::af::mixed_x(&m));
    } else {
        var t: cpp::af::tight = {};
        t.set_x(9);
        var m: cpp::af::mixed = {};
        m.set_x(11);
        std::println("c++14 {} {}", cpp::af::tight_x(&t), cpp::af::mixed_x(&m));
    }
}
