// C++ headers written for different standards in one program, each read and compiled under its own:
// C++98 for the one that uses what C++17 removed, C++11 and C++17 for two more, the newest the
// compiler accepts for the C++20 and C++23 ones
use std::io;
@attributes([@standard("c++98")])
use { "v98.hpp" } as old;
@attributes([@standard("c++11")])
use { "v11.hpp" } as v11;
@attributes([@standard("c++17")])
use { "v17.hpp" } as v17;
use { "v20.hpp" } as v20;
use { "v23.hpp" } as v23;

fn main() -> void {
    std::println("{} {}", old::v98::old_sum(2, 3), old::v98::owned_value(21));
    std::println("{} {} {}", v11::v11::sq(7), v11::v11::add(1, 2), v11::v11::code(v11::v11::color::green));
    std::println("{} {} {}", v17::v17::len("volt"), v17::v17::pick<i64>(1, 2), v17::v17::pair_sum());
    std::println("{} {}", v20::v20::half(@cast<i32>(9)), v20::v20::made());
    std::println("{} {} {}", v23::v23::when(4), v23::v23::checked(5), v23::v23::counted());
}
