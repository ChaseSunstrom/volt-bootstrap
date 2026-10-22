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

// a result mirror other than the parameter's: U zeroed
template <class T, class U>
auto conv(T x) {
    U u;
    std::memset(&u, 0, sizeof(U));
    return u;
}

// a reference to a mirror, with no receiver or reference argument it could be into: a copy
template <class T>
auto& global() {
    static T t;
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

// reference results of a method: pick's is into its argument (a value Volt passed, so the wrapper's
// own copy: a copy comes back), at_n's into the object (its argument by value: a reference)
struct holder {
    int n;
    template <class T>
    const auto &pick(const T &v) const {
        return v;
    }
    template <class T>
    auto &at_n(T) {
        return n;
    }
};
}
