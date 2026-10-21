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
}
