// a C++ enum's T(&)[N] (a plain enum, an enum class : uint8_t) takes the Volt array of the Volt
// enum, laid out as C++'s: C++ writes into it; a const one takes it by value
use std::io;
use { "cpp_array_ref.hpp" } as cpp;
fn main() -> void {
    var cs: cpp::ar::Color[3] = { cpp::ar::Color::RED, cpp::ar::Color::GREEN, cpp::ar::Color::BLUE };
    cpp::ar::rotate(&cs);
    std::println("rotate {} {} {}", @cast<i32>(cs[0]), @cast<i32>(cs[1]), @cast<i32>(cs[2]));
    var ls: cpp::ar::Level[2] = { cpp::ar::Level::LOW, cpp::ar::Level::MID };
    std::println("sum {}", cpp::ar::level_sum(ls));
    cpp::ar::raise(&ls);
    std::println("raise {} {} {}", @cast<i32>(ls[0]), @cast<i32>(ls[1]), cpp::ar::level_sum(ls));
}
