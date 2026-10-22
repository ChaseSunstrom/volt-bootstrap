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
}
