// a class template Volt declares (its fields public) with method templates: instance and static,
// deduced and with the template argument given, worked out per use (T-0640)
#pragma once

namespace twc {
template <class U>
struct Bag {
    U base;
    int plain(int x) { return x + (int)base; }
    template <class T> int one(T x) { return (int)x + (int)base; }
    template <class T> T cast_to() const { return (T)base; }
    template <class T> static int sz(T) { return (int)sizeof(T); }
};
// with a value parameter: its static's class spelled with the number
template <class T, int N>
struct Tag {
    T base;
    template <class U> static int sz(U) { return (int)sizeof(U) + N; }
};
}
