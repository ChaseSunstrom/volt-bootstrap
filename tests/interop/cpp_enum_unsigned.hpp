// unsigned-backed enums whose values pass the signed range of their width (cpp_enum_unsigned.volt)
#pragma once
#include <cstdint>

namespace eu {
enum class level : std::uint8_t { LOW = 1, HIGH = 200 };
enum big : unsigned long long { ONE = 1, TOP = 0xFFFFFFFFFFFFFFFFull };

inline level up(level l) { return l == level::LOW ? level::HIGH : level::LOW; }
inline big flip(big b) { return b == TOP ? ONE : TOP; }
inline unsigned level_value(level l) { return static_cast<unsigned>(l); }

constexpr level loud = level::HIGH;
constexpr big most = TOP;
}
