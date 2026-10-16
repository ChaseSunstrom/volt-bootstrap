// Parameters that take a Volt form of their own (cpp_params.volt): references to arrays (one through
// an alias, with a default), function pointers, a std::string& (one changed and then thrown from, one
// a result would point into), std::functions over classes (one move-only)
#pragma once
#include <functional>
#include <map>
#include <memory>
#include <stdexcept>
#include <string>
#include <string_view>
#include <unordered_map>
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
// callables, worked out per use (a pack has no Volt generic form): fns of no parameters, and C
// variadic ones (snprintf)
template <class... F> int call0(F... f) { return (0 + ... + f()); }
template <class... F> int callv(F... f) { unsigned char b[16]; return (0 + ... + f(b, sizeof b, "%d-%d", 12, 345)); }
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
// an S& / const S& pair: C++ runs S& for a string Volt can change, const S& for one it can't; a
// forwarding S&& changes it
template <class S> int which(S &s) { s += "&"; return 1; }
template <class S> int which(const S &) { return 2; }
template <class S> int fwd(S &&s) { s += "&&"; return (int)s.size(); }
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
// an auto result: the probe instantiates the body (given text, it doesn't compile: cpp_params_bad_call.volt)
template <class... A> auto fold_t(A... a) { return (0 + ... + a); }
// templates: made per use, a nested Volt slice spelled as nested std::vectors for the probe
template <class T> std::string rows_t(const std::vector<std::vector<T> > &v) { return rows(v); }
template <class T> T deep_t(std::vector<std::vector<std::vector<T> > > v) { T s = 0; for (std::size_t i = 0; i < v.size(); i++) for (std::size_t j = 0; j < v[i].size(); j++) for (std::size_t k = 0; k < v[i][j].size(); k++) s += v[i][j][k] * (T)(i + 1); return s; }
}
// std::map / std::unordered_map parameters take a Volt std::map&: each prints C++'s own order (the
// unordered one copied into a std::map first), beside a stdcxx handle form when there is one; a
// mutable one keeps its handle form (or stays per use), and one of bools stays per use
namespace mp {
template <class M, class F> std::string show(const M &m, F val) { std::string s = "{"; for (auto &kv : m) s += (s.size() > 1 ? "," : "") + kv.first + ":" + val(kv.second); return s + "}"; }
inline std::string num(int x) { return std::to_string(x); }
inline std::string dump(const std::map<int, int> &m) { std::string s = "{"; for (auto &kv : m) s += (s.size() > 1 ? "," : "") + num(kv.first) + ":" + num(kv.second); return s + "}"; }
inline std::string dump_u(std::unordered_map<int, double> m) { std::map<int, double> o(m.begin(), m.end()); std::string s = "{"; for (auto &kv : o) s += (s.size() > 1 ? "," : "") + num(kv.first) + ":" + num((int)(kv.second * 100)); return s + "}"; }
inline std::string dump_s(const std::map<std::string, int> &m) { return show(m, num); }
inline std::string dump_ss(const std::map<std::string, std::string> &m) { return show(m, [](const std::string &v) { return "'" + v + "'"; }); }
inline std::string dump_v(const std::map<int, std::vector<int>> &m) { std::string s = "{"; for (auto &kv : m) { s += (s.size() > 1 ? "," : "") + num(kv.first) + ":["; for (std::size_t i = 0; i < kv.second.size(); i++) s += (i ? "," : "") + num(kv.second[i]); s += "]"; } return s + "}"; }
inline int dump_rv(std::map<int, int> &&m) { std::map<int, int> mine(std::move(m)); int t = 0; for (auto &kv : mine) t += kv.first * kv.second; return t; }
using imap = std::map<int, int, std::less<int>>;
inline std::size_t dump_a(const imap &m) { return m.size(); }
inline int put_in(std::map<int, int> &m) { m[7] = 7; return (int)m.size(); }
inline int put_s(std::map<std::string, int> &m) { m["z"] = 7; return (int)m.size(); }
inline int bits(const std::map<int, std::vector<bool>> &m) { return (int)m.size(); }
inline int pick_k(const std::map<int, int> &m, int k) { auto i = m.find(k); if (i == m.end()) throw std::out_of_range("no key"); return i->second; }
// const& beside &&: one Volt std::map& form for the two
inline int both(const std::map<int, int> &) { return 1; }
inline int both(std::map<int, int> &&) { return 2; }
// results that would point into the map's copy: not declared with a Volt std::map& (the handle
// forms stay)
inline const int *find(const std::map<int, int> &m, int k) { return &m.find(k)->second; }
inline std::string_view key0(const std::map<std::string, int> &m) { return m.begin()->first; }
inline const std::vector<int> &row0(const std::map<int, std::vector<int>> &m) { return m.begin()->second; }
}
// calls worked out per use that throw (cpp_params_try.volt): their try_ forms catch, a std::string&
// left as it was; a try_ name the header declares itself keeps it
namespace pu {
template <class... A> int checked(A... a) {
    int s = (0 + ... + a);
    if (s < 0) throw std::invalid_argument("negative sum");
    return s;
}
template <class... A> int stretch(std::string &s, A... n) {
    s += "~";
    int k = (0 + ... + n);
    if (k < 0) throw std::out_of_range("short");
    s.append(k, '+');
    return (int)s.size();
}
template <class... A> void boom(A... a) {
    if (sizeof...(a) > 1) throw std::length_error("too many");
}
template <class... A> int twin(A... a) { return (0 + ... + a); }
inline int try_twin(int x) { return -x; }
// declared, not per use: a try_ name the header declares beside a throwing function keeps it too
inline int sole(int x) {
    if (x < 0) throw std::invalid_argument("negative sole");
    return x;
}
inline int try_sole(int x) { return -x; }
inline int lone(int x) {
    if (x < 0) throw std::invalid_argument("negative lone");
    return x;
}
struct Gauge {
    int v = 1;
    int read(int k) {
        if (k < 0) throw std::domain_error("negative read");
        return v + k;
    }
    int try_read(int k) { return -k; }
};
inline int nonneg(int x) {
    if (x < 0) throw std::invalid_argument("negative");
    return x;
}
// held by handle, its members worked out per use: x.try_m(...) and T::try_new(...) catch too
template <class T> class Keep {
    T v_;
  public:
    explicit Keep(T v) : v_(v) {
        if (v < 0) throw std::domain_error("negative keep");
    }
    Keep(std::string &s, T v) : v_(v) {
        s += "~";
        if (v < 0) throw std::domain_error("negative keep");
    }
    T take(int k) const {
        if (k < 0) throw std::out_of_range("no take");
        return v_ + k;
    }
    T grow(std::string &s, int k) const {
        s += "~";
        if (k < 0) throw std::out_of_range("no grow");
        s.append(k, '+');
        return v_ + k;
    }
};
// one name declared (pick(int)) and worked out per use (the template): try_pick catches either
inline int pick(int x) {
    if (x < 0) throw std::invalid_argument("negative pick");
    return x;
}
template <class... A> int pick(A... a) {
    int s = (0 + ... + a);
    if (s < 0) throw std::range_error("negative picks");
    return s;
}
}
// a Volt reference reaches a call worked out per use (a variadic template, a function beside a
// parameter with no Volt form) as an lvalue of what it names (f(x)), and as its address (f(&x)) only
// when no call takes the lvalue: T*, a template's T* deducing T; a declared template's S deduced
// from a reference is what it names
namespace rp {
typedef std::vector<std::vector<bool>> skips;
template <class T, class... A> T deref(T *p, A...) { *p += 1; return *p; }
inline int sum_ptr(int *p, int n, const skips &s = skips()) { int t = 0; for (int i = 0; i < n; i++) t += p[i]; return t + (int)s.size(); }
inline int which(int &, const skips & = skips()) { return 1; }
inline int which(int *, const skips & = skips()) { return 2; }
inline int mixed(int &a, int *b, const skips & = skips()) { return a + *b; }
template <class T, class... A> T checked(T *p, A...) {
    if (*p < 0) throw std::invalid_argument("negative pointee");
    return *p;
}
template <class S> int size_of(S &) { return (int)sizeof(S); }
template <class S> int size_by(S) { return (int)sizeof(S); }
template <class S> void twice_ref(S &s) { s *= 2; }
struct pt { int x; int y; };
// a class template held by handle, its members worked out per use: a pointer argument beside the
// receiver, of an & method, an && one (which consumes the handle) and an operator
template <class T> class Tally {
    T v_;
  public:
    Tally(T v) : v_(v) {}
    T add(T *p) { *p += v_; return *p; }
    T spend(T *p) && { *p += 2 * v_; return *p; }
    T operator+(T *p) const { return v_ + *p; }
};
}
}
// pr::pu opened again: a try_ name declared in a later block of the namespace is still beside lone
namespace pr {
namespace pu {
inline int try_lone(int x) { return -x - 1; }
}
}
// results that may point into a temporary made for a parameter (a Volt slice's std::vector, a str's
// std::string): not declared, an error per use; the rest are (back_ref's int is copied out in the call)
namespace tc {
inline const int *data_of(const std::vector<int> &v) { return v.data(); }
inline const int &back_ref(const std::vector<int> &v) { return v.back(); }
inline const char *cstr_of(const std::string &s) { return s.c_str(); }
inline int sum_of(const std::vector<int> &v) { int s = 0; for (std::size_t i = 0; i < v.size(); i++) s += v[i]; return s; }
inline std::vector<int> twice_of(const std::vector<int> &v) { std::vector<int> r(v); for (std::size_t i = 0; i < r.size(); i++) r[i] *= 2; return r; }
inline std::size_t len_of(const std::string &s) { return s.size(); }
template <class T> const T *ptr_t(const std::vector<T> &v) { return v.data(); }
}
