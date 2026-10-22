// below C++17 (run with --cc -std=c++14): an instance of a class template held by handle, on a
// class aligned to 32, can't be made: plain new doesn't align it there, so its build fails naming
// C++17's aligned new (T-0645)
use std::io;
use { "cpp_aligned_field.hpp" } as cpp;

fn main() -> void {
    var tb: cpp::af::tbox32 = {};
    std::println("box {}", tb.get());
}
