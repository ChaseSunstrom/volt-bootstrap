// templates Volt can't declare ahead (an auto result: each call is made per use) whose result is a
// Volt type C++ has no type for (its mirror): it comes back as that Volt type
#pragma once
#include <cstring>

namespace pu4 {
template <class T>
auto echo(T x) {
    return x;
}

// T only explicit: the result is the only place its mirror is named
template <class T>
auto zero() {
    T t;
    std::memset(&t, 0, sizeof(T));
    return t;
}

// a pointer to the mirror
template <class T>
auto addr(T* x) {
    return x;
}

// a null pointer to the mirror, named only in the result
template <class T>
auto nowhere() {
    return (T*)0;
}
}
