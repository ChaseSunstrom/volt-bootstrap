// C++23: if consteval, std::expected, deducing this
#pragma once
#include <expected>
namespace v23 {
constexpr int when(int x) {
    if consteval { return x; } else { return x + 1; }
}
inline int checked(int x) {
    std::expected<int, int> e = x >= 0 ? std::expected<int, int>(x * 3) : std::unexpected(-1);
    return e.value_or(-1);
}
struct counter {
    int n = 0;
    template <class Self> auto get(this Self &&self) { return self.n; }
};
inline int counted() { counter c{ 5 }; return c.get(); }
}
