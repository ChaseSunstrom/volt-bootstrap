// templates Volt can't declare ahead (an auto result: each call is made per use) called with an
// explicit template argument naming a Volt type C++ has no type for: it comes as its mirror, as a
// deduced one does
#pragma once
#include <cstddef>

namespace pu3 {
template <class T>
auto echo(T x) {
    return x;
}

// T only explicit: nothing to deduce it from
template <class T>
auto size_of() {
    return sizeof(T);
}
}
