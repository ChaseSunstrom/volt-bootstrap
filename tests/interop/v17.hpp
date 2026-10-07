// C++17: string_view, if constexpr, structured bindings, inline variables
#pragma once
#include <string_view>
#include <utility>
namespace v17 {
inline constexpr int base = 100;
inline std::size_t len(std::string_view s) { return s.size(); }
template <class T> T pick(T a, T b) {
    if constexpr (sizeof(T) >= 8) return a; else return b;
}
inline int pair_sum() {
    auto [a, b] = std::pair<int, int>(3, 4);
    return a + b + base;
}
}
