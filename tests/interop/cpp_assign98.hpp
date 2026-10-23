// C++98 declares a class's assignment even when it can't be defined (a const or reference member,
// or a member or base with one) and fails only where it's used, so Volt checks the members itself
// (cpp_assign98.volt): no set_ for such a field, no Volt form for such a mutable T(&)[N]
#pragma once
#include <string>
namespace as98 {
struct Pin {
    const int id;
    std::string tag;
    Pin(int i) : id(i) {}
    int get() const { return id; }
};
struct Ref {
    int &r;
    Ref(int &x) : r(x) {}
};
struct Derived : Pin {
    Derived(int i) : Pin(i) {}
};
// its own assignment: taken at its word
struct Own {
    const int id;
    int n;
    Own(int i) : id(i), n(0) {}
    Own &operator=(const Own &o) {
        n = o.n;
        return *this;
    }
};
struct Bag {
    Pin p;
    Derived d;
    Own o;
    int n;
    Bag() : p(1), d(2), o(3), n(4) {}
};
inline int pin_id(const Pin &p) { return p.id; }
inline void pin_touch(Pin (&p)[2]) { p[0].tag = "x"; }
inline int ref_value(const Ref &r) { return r.r; }
}
