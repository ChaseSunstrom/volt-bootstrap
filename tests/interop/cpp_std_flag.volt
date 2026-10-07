// a standard for the whole program (--cc -std=c++14): v98.hpp, which uses what C++17 removed, needs
// no @standard of its own
use std::io;
use { "v98.hpp" } as old;

fn main() -> void {
    std::println("{} {}", old::v98::owned_value(21), @cpp<i64>("__cplusplus"));
}
