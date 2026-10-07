// The C++ standard library in a header's signatures: optional, pair, tuple, array, span,
// string_view and variant, and a view (cpp_stdlib.volt reads each as Volt's own form)
#pragma once
#include <array>
#include <optional>
#include <ranges>
#include <span>
#include <string_view>
#include <tuple>
#include <utility>
#include <variant>

namespace sl {
inline std::optional<int> half(int x) {
    if (x % 2) return std::nullopt;
    return x / 2;
}
inline int or_minus(std::optional<int> o) { return o.value_or(-1); }
inline std::pair<int, double> split(double x) { return {static_cast<int>(x), x - static_cast<int>(x)}; }
inline std::tuple<int, bool, double> info(int x) { return {x * 2, x > 0, x / 4.0}; }
inline std::array<int, 3> triple(int x) { return {x, x + 1, x + 2}; }
inline int sum3(const std::array<int, 3> &a) { return a[0] + a[1] + a[2]; }
inline long total(std::span<const long> xs) {
    long t = 0;
    for (long x : xs) t += x;
    return t;
}
inline std::string_view word(int i) {
    static const char *w[] = {"zero", "one", "two"};
    return w[i];
}
inline std::size_t length(std::string_view s) { return s.size(); }
inline std::variant<int, double> parse(bool real) {
    if (real) return 2.5;
    return 7;
}
inline double join(std::pair<int, double> p) { return p.first + p.second; }
inline int pick(const std::tuple<bool, int, int> &t) { return std::get<0>(t) ? std::get<1>(t) : std::get<2>(t); }
inline double widen(std::variant<int, double> v) { return v.index() == 0 ? std::get<0>(v) : std::get<1>(v) * 10; }
inline auto squares(int n) {
    return std::views::iota(0, n) | std::views::transform([](int i) { return i * i; });
}
}
