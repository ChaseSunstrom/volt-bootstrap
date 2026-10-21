// ref-qualified method template pairs f(T&) / f(T) (C++11: cpp_twin.hpp is C++98 too): each
// wrapper names its own overload through a member pointer carrying the qualifiers
#pragma once

namespace tw {
class Acc {
    int base;
public:
    Acc(int b) : base(b) {}
    template <class T> int rr(T &x) && { x += base; return 500; }
    template <class T> int rr(T x) && { return 600 + base + (int)x; }
    template <class T> int cr(const T &x) const & { return 700 + base + (int)x; }
    template <class T> int cr(T x) const & { return 800 + base + (int)x; }
};
}
