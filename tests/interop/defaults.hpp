// Which parameters have a default argument (cpp_defaults.volt): found from a top-level = in the
// parameter's own tokens, not from where an expression sits in it. An array reference's bound, a
// std::array's size and a decltype are expressions with no default; an alias's reference, a
// parenthesized expression and a decltype followed by = 0 have one; a template's = is not a parameter's
#pragma once
#include <array>
#include <map>
#include <vector>
namespace df {
inline int g3[3] = {7, 8, 9};
using Arr = int[3];
inline int ref_plain(int (&a)[3]) { return a[0]; }
inline int ref_alias(Arr &a = g3) { return a[1]; }
inline int expr(int x = (1 + 2)) { return x; }
inline int arr(std::array<int, 3> a) { return a[2]; }
inline int dt(decltype(1) x = 0) { return x + 10; }
inline int dt_plain(decltype(1 + 2) x) { return x; }
inline int cmp(decltype(1 < 2) x = true) { return x; }
inline int tail(int a[3]) { return a[0]; }
inline int tail_def(int a[3] = g3) { return a[1]; }
inline int g(std::vector<int> v = {}) { return (int)v.size(); }
inline int h(int = 3) { return 3; }
inline int fb(int x) { return x + 1; }
inline int p(int (*f)(int) = nullptr) { return f ? f(1) : 0; }
inline int a([[maybe_unused]] int x = 1) { return 1; }
template <int N = 4> int tp(int x) { return x + N; }
}
