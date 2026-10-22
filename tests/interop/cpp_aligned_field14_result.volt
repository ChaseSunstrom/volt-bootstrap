// below C++17 (run with --cc -std=c++14): a function's result of a template handle's instance aligned
// to 32 is copied into a new handle, which plain new can't align: its build fails naming C++17's
// aligned new (T-0645)
use std::io;
use { "cpp_aligned_field.hpp" } as cpp;

fn main() -> void {
    val made = cpp::af::make_box32();
    std::println("box {}", made.get());
}
