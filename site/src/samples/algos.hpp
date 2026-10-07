// C++ that Volt can't declare ahead, called per use (the C++ page's "Calls worked out per use")
#pragma once
#include <concepts>
#include <cstddef>

#define CLAMP01(x) ((x) < 0 ? 0 : (x) > 1 ? 1 : (x))

namespace algo {

template <class... A>
auto sum(A... a) { return (a + ... + 0); }

template <std::size_t N>
std::size_t padded(std::size_t n) { return (n + N - 1) / N * N; }

template <std::integral T>
T halve(T x) { return x / 2; }

} // namespace algo
