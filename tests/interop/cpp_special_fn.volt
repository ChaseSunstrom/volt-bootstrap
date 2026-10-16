// Function template specializations: C++ picks them, called per use from Volt (pick<int> returns
// 2 where the primary returns 1; Meter::unit<double> 20 more than its base, the primary 10)
use std::io;
use { "special.hpp" } as cpp;

fn main() -> void {
    std::println("{} {} {}", cpp::sp::pick(1), cpp::sp::pick(1.5), cpp::sp::pick<i32>(3));
    val m: cpp::sp::Meter = { base: 5 };
    std::println("{} {}", m.unit(2.5), m.unit(1));
}
