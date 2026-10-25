// templates Volt can't declare ahead (an auto result: each call is made per use) called with an
// explicit template argument naming a Volt type C++ has no type for: it comes as its mirror, as a
// deduced one does
#pragma once
#include <cstddef>
#include <cstring>

namespace pu3 {
// T only explicit: nothing to deduce it from
template <class T>
auto size_of() {
    return sizeof(T);
}

// the bytes C++ was given, compared
template <class T>
auto same(T a, T b) {
    return std::memcmp(&a, &b, sizeof(T)) == 0;
}

// a Volt struct's fields by name, a nested struct's, a tuple's (_0, _1), and a changed copy back
template <class T>
auto area(T r) {
    return r.w * r.h;
}

template <class T>
auto span_x(T s) {
    return s.b.x - s.a.x;
}

template <class T>
auto sum2(T t) {
    return t._0 + t._1;
}

template <class T>
auto bump(T r) {
    r.w += 1;
    return r;
}

// a struct pointing at its own type: its mirror is declared ahead
template <class T>
auto second(T n) {
    return n.next->v;
}
}
