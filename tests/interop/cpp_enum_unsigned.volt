// an enum class : uint8_t with 200 and an enum : unsigned long long with 2^64 - 1 import with their
// values read unsigned, pass through C++ by value, and their constexpr constants name the enumerator
use std::io;
use { "cpp_enum_unsigned.hpp" } as cpp;
fn main() -> void {
    std::println("values {} {}", @cast<u8>(cpp::eu::level::HIGH), @cast<u64>(cpp::eu::big::TOP));
    val h = cpp::eu::up(cpp::eu::level::LOW);
    std::println("up {} {}", @cast<u8>(h), cpp::eu::level_value(h));
    std::println("flip {} {}", @cast<u64>(cpp::eu::flip(cpp::eu::big::ONE)), @cast<u64>(cpp::eu::flip(cpp::eu::big::TOP)));
    std::println("consts {} {}", @cast<u8>(cpp::eu::loud), @cast<u64>(cpp::eu::most));
}
