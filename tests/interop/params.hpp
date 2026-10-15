// Parameters that take a Volt form of their own (cpp_params.volt): references to arrays (one through
// an alias, with a default), function pointers, a std::string& (one changed and then thrown from, one
// a result would point into), std::functions over classes (one move-only)
#pragma once
#include <functional>
#include <memory>
#include <stdexcept>
#include <string>
#include <string_view>
#include <vector>
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
// a C++ callable taking a std::string&, which Volt keeps and calls
inline std::function<void(std::string &)> exclaimer(int n) { return [n](std::string &s) { s.append(n, '?'); }; }
inline int grow(std::string &s, int n) {
    s += "~";
    if (n < 0) throw std::invalid_argument("negative");
    s.append(n, '+');
    return (int)s.size();
}
// a view into the string: Volt's copy of it is gone once the call returns, so this isn't declared
inline std::string_view first_word(std::string &s) { return std::string_view(s).substr(0, s.find(' ')); }
// structs a std::string& call returns: one holding a pointer into the string, one a view (both left
// out: they'd point into the copy), and plain values (fine, the string written back)
struct word_at { const char *p; int n; };
inline word_at first_at(std::string &s) { word_at w = {s.data(), 1}; return w; }
struct named { int k; std::string_view v; };
inline named name_of(std::string &s) { named n = {2, s}; return n; }
struct counted { int n; long total; };
inline counted count_up(std::string &s) { s += "+"; counted c = {(int)s.size(), 7}; return c; }
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
// parameters written as arrays are pointers (a size or none, const, with a default)
namespace ap {
inline int g3[3] = {7, 8, 9};
inline int sum3(int a[3]) { a[2] += 1; return a[0] + a[1] + a[2]; }
inline int total(const int a[], int n) { int s = 0; for (int i = 0; i < n; i++) s += a[i]; return s; }
inline int tail(int a[3] = g3) { return a[2]; }
template <class T> T head(const T a[]) { return a[0]; }
using Arr3 = int[3];
inline int sum_alias(Arr3 a) { return a[0] + a[1] + a[2]; }
inline int first_char(const char s[]) { return s[0]; }
inline int byte0(unsigned char buf[16]) { return buf[0]; }
inline int argc_of(char *argv[]) { int n = 0; while (argv[n]) n++; return n; }
inline int grid(int a[2][3]) { return a[1][2]; }
struct cell { int x; int y; };
inline int cells(const cell a[], int n) { int s = 0; for (int i = 0; i < n; i++) s += a[i].x * a[i].y; return s; }
}
// templates written against a C++ string, which a Volt std::string crosses as one (a copy, written
// back for S&); one also called with an int, one with a second parameter, one that throws; S nested
// in another type or the result isn't taken
namespace gs {
template <class S> void wrap(S &s) { s.append("!"); }
template <class S> std::size_t len(const S &s) { return s.size(); }
template <class S> int bump(S s) { s += "??"; return (int)s.size(); }
inline int measure(const std::string &s) { return (int)s.size(); }
inline int measure(int v) { return v; }
template <class S> int gauge(const S &s) { return measure(s) * 10; }
template <class S, class T> int pad(S &s, T n) { s.append(n, '#'); return (int)s.size(); }
template <class S> int grow(S &s, int n) {
    s += "~";
    if (n < 0) throw std::invalid_argument("negative");
    s.append(n, '+');
    return (int)s.size();
}
template <class S> int count_all(const std::vector<S> &v) { return (int)v.size(); }
template <class S> int deref(S *p) { return (int)p->size(); }
template <class S> S echo(const S &s) { return s; }
}
// nested std::vectors, by value, const& and && (a Volt slice of slices, each level copied; of ints,
// doubles and signed chars, whose Volt form is the same on every target), written back
// as text so a wrong split or order shows; a mutable one, one of bools and one of a class stay per
// use
namespace nv {
inline std::string row(const std::vector<int> &r) { std::string s = "["; for (std::size_t i = 0; i < r.size(); i++) s += (i ? "," : "") + std::to_string(r[i]); return s + "]"; }
inline std::string rows(const std::vector<std::vector<int>> &v) { std::string s = "["; for (std::size_t i = 0; i < v.size(); i++) s += (i ? "," : "") + row(v[i]); return s + "]"; }
inline std::string shape(std::vector<std::vector<int>> v) { return rows(v); }
inline std::string shape_ref(const std::vector<std::vector<int>> &v) { return rows(v); }
inline std::string shape3(const std::vector<std::vector<std::vector<int>>> &v) { std::string s = "["; for (std::size_t i = 0; i < v.size(); i++) s += (i ? "," : "") + rows(v[i]); return s + "]"; }
inline std::string shape_rv(std::vector<std::vector<int>> &&v) { std::vector<std::vector<int>> mine(std::move(v)); return rows(mine); }
inline double weigh(const std::vector<std::vector<double>> &v) { double s = 0; for (std::size_t i = 0; i < v.size(); i++) for (std::size_t j = 0; j < v[i].size(); j++) s += v[i][j] * (double)(i + 1); return s; }
inline std::string spell(std::vector<std::vector<signed char>> v) { std::string s; for (std::size_t i = 0; i < v.size(); i++) { if (i) s += '/'; s.append(v[i].begin(), v[i].end()); } return s; }
inline int widen(std::vector<std::vector<int>> &v) { v.push_back(std::vector<int>()); return (int)v.size(); }
inline int flags(const std::vector<std::vector<bool>> &v) { return (int)v.size(); }
inline int boxes(const std::vector<std::vector<Shape>> &v) { return (int)v.size(); }
}
}
