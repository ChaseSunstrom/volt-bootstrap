// C++20: concepts, consteval, designated initializers, the spaceship operator
#pragma once
#include <compare>
#include <concepts>
namespace v20 {
template <std::integral T> T half(T x) { return x / 2; }
consteval int ten() { return 10; }
struct pt { int x, y; auto operator<=>(const pt &) const = default; };
inline int made() { pt p{ .x = 1, .y = ten() }; return p.x + p.y; }
}
