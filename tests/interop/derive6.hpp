// virtual operators, an && method and C variadic virtuals a Volt type overrides (cpp_derive6.volt)
#pragma once
#include <cstdarg>
#include <utility>

namespace d6 {
struct V {
    virtual ~V() {}
    virtual bool operator==(int x) const { return x == 0; }
    virtual int operator()(int a, int b) { return a - b; }
    virtual int take() && { return 1; }
    virtual int log(const char *fmt, ...) { return -1; }
    virtual int sum(int n, ...) = 0;
};
inline int eq(const V &v, int x) { return v == x ? 1 : 0; }
inline int call(V &v) { return v(10, 3); }
inline int taken(V &v) { return std::move(v).take(); }
inline int logged(V &v) { return v.log("%d", 7); }
inline int summed(V &v) { return v.sum(3, 1, 2, 3); }
}
