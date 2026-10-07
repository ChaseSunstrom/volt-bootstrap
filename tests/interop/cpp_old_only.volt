// a program whose only C++ import is under an older standard: its own @cpp calls go in that
// import's unit, which has its headers
use std::io;
@attributes([@standard("c++98")])
use { "v98.hpp" } as old;

fn main() -> void {
    std::println("{}", @cpp<i32>("v98::old_sum({0}, {1})", 20, 22));
}
