// Parameters that take a Volt form of their own (cpp_params.volt): references to arrays (one through
// an alias, with a default), function pointers, a std::string& (one changed and then thrown from, one
// a result would point into), std::functions over classes (one move-only)
#pragma once
#include <functional>
#include <memory>
#include <stdexcept>
#include <string>
#include <string_view>
namespace pr {
inline int sum(const int (&a)[3]) { return a[0] + a[1] + a[2]; }
inline void fill(int (&a)[3], int v) { for (int &x : a) x = v; }
template <class T, int N> T total(const T (&a)[N]) { T s = 0; for (const T &x : a) s += x; return s; }
template <int N> void twice(int (&a)[N]) { for (int &x : a) x *= 2; }
using Arr = int[3];
inline int defaults[3] = {7, 8, 9};
inline int first_of(Arr &a = defaults) { return a[0]; }
inline int apply(int (*f)(int), int x) { return f(x); }
inline double fold(double (*f)(double, double), double a, double b) { return f(a, b); }
template <class T> T apply_t(T (*f)(T), T x) { return f(x); }
inline void shout(std::string &s, int n) { s.append(n, '!'); }
inline int grow(std::string &s, int n) {
    s += "~";
    if (n < 0) throw std::invalid_argument("negative");
    s.append(n, '+');
    return (int)s.size();
}
// a view into the string: Volt's copy of it is gone once the call returns, so this isn't declared
inline std::string_view first_word(std::string &s) { return std::string_view(s).substr(0, s.find(' ')); }
inline int relay(const std::function<int(int)> &f) { return f(-1); }
// a class Volt holds by handle (it isn't trivially copyable) and one it lays out, in a std::function
class Shape {
  public:
    explicit Shape(int sides) : sides_(sides), name_("shape" + std::to_string(sides)) {}
    int sides() const { return sides_; }
  private:
    int sides_;
    std::string name_;
};
struct point { int x; int y; };
inline int each_shape(const std::function<void(const Shape &)> &f) { Shape a(3), b(4); f(a); f(b); return 2; }
inline int sum_points(std::function<int(point)> f) { point p = {1, 2}, q = {10, 20}; return f(p) + f(q); }
inline int far(const std::function<point(int)> &f) { point p = f(5); return p.x - p.y; }
// a move-only class, by value in a std::function
class Token {
  public:
    explicit Token(int v) : v_(new int(v)) {}
    int value() const { return *v_; }
  private:
    std::unique_ptr<int> v_;
};
inline int spend(const std::function<int(Token)> &f) { return f(Token(7)) + f(Token(8)); }
}
