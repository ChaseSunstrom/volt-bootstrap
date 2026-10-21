// templates that take anything, called per use with Volt types C++ has no type for; and results
// Volt holds as a function pointer and an array reference
#pragma once
#include <cstddef>

namespace pu2 {
template <class T>
T echo(T x) {
    return x;
}

template <class F>
int call(F f) {
    return f(20);
}

template <class... A>
std::size_t count(A...) {
    return sizeof...(A);
}

inline int add1(int x) {
    return x + 1;
}

typedef int (*unary)(int);

inline unary pick() {
    return add1;
}

inline int (&nums())[3] {
    static int a[3] = {4, 5, 6};
    return a;
}

template <class T>
T &same(T &x) {
    return x;
}
}
