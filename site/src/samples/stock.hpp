// stock.hpp: the standard library's types in a header's signatures (cpp.md, "Types by what they can do")
#pragma once
#include <map>
#include <optional>
#include <span>
#include <string>
#include <tuple>
#include <variant>

namespace stock {
inline std::optional<int> find(std::span<const int> xs, int x) {
    for (std::size_t i = 0; i < xs.size(); i++) {
        if (xs[i] == x) return static_cast<int>(i);
    }
    return std::nullopt;
}
inline std::tuple<int, int, bool> minmax(std::span<const int> xs) {
    int lo = xs[0], hi = xs[0];
    for (int x : xs) {
        lo = x < lo ? x : lo;
        hi = x > hi ? x : hi;
    }
    return {lo, hi, lo == hi};
}
inline std::variant<int, double> price(bool exact) {
    if (exact) return 3;
    return 2.75;
}
inline std::map<int, int> counts(std::span<const int> xs) {
    std::map<int, int> m;
    for (int x : xs) m[x]++;
    return m;
}
}
