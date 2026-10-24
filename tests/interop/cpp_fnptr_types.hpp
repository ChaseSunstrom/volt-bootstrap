// function pointer parameters whose signature has a class, an enum or a reference
// (cpp_fnptr_types.volt): a named Volt fn of that signature
#pragma once
#include <vector>

namespace fp {
struct Shape {
    double w, h;
};
enum class Mode : int { OFF, ON, AUTO };
enum Small : unsigned char { S0, S1, S9 = 9 };

inline double each(const std::vector<Shape> &v, double (*f)(const Shape &)) {
    double t = 0;
    for (const Shape &s : v) t += f(s);
    return t;
}
inline void on(Mode m, void (*cb)(Mode)) { cb(m); }
inline int small(Small s, int (*f)(Small)) { return f(s); }
inline Mode next(Mode m, Mode (*f)(Mode)) { return f(m); }
inline void grow(Shape &s, void (*f)(Shape &)) { f(s); }
inline int bump(int x, void (*f)(int &)) { f(x); return x; }
inline double bigger(const Shape &a, const Shape &b, const Shape &(*f)(const Shape &, const Shape &)) {
    const Shape &r = f(a, b);
    return &r == &a ? 1.0 : 2.0;
}
// worked out per use (templates): the fn crosses through volt_fn_as
template <class T> T scale(T x, double (*f)(const Shape &), const Shape &s) { return x * (T)f(s); }
template <class T> double twice(const T &a, double (*f)(const T &)) { return 2 * f(a); }
template <class T> T small_t(T x, int (*f)(Small)) { return x + (T)f(S1); }
template <class F> int with_ref(F f) { int x = 4; f(x); return x; }
// function pointer results of those types (a Volt extern "C" fn of the signature)
inline double area_of(const Shape &s) { return s.w * s.h; }
inline double (*pick_area())(const Shape &) { return &area_of; }
inline int &seen() { static int s = -1; return s; }
inline void note_mode(Mode m) { seen() = (int)m; }
inline void (*pick_mode())(Mode) { return &note_mode; }
inline int mode_seen() { return seen(); }
}
