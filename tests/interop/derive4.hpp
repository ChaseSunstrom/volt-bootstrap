// Subclassing a C++ class from Volt (cpp_derive4.volt): a virtual method's & twin declared after
// its && one, overloads that differ only in const (the _const and _nonconst names), one whose
// suffixed name a virtual method already has, and a reference to a class held by handle
#pragma once
#include <string>
#include <utility>

namespace d4 {
class Item {
  public:
    explicit Item(int v) : v_(v) {}
    int v() const { return v_; }

  private:
    int v_;
    std::string tag_ = "item";
};

class Q {
  public:
    virtual ~Q() = default;
    // && first: the & twin is overridable as g
    virtual int g() && { return 0; }
    virtual int g() & { return 1; }
    // const first: the other is h_nonconst
    virtual int h() const { return 2; }
    virtual int h() { return 3; }
    // const second: k_const, p_int_const
    virtual int k() { return 4; }
    virtual int k() const { return 5; }
    virtual int p(int x) { return x; }
    virtual int p(int x) const { return x + 1; }
    // d(double) would be d_double, a virtual method's own name: it stays C++'s
    virtual int d(int x) { return x; }
    virtual int d(double x) { return (int)x; }
    virtual int d_double() { return 4; }
    virtual const Item &pick() const { return it_; }

  private:
    Item it_{5};
};

inline int use_g(Q &q) { return q.g() * 10 + std::move(q).g(); }
inline int use_h(Q &q) {
    const Q &c = q;
    return c.h() * 100 + q.h();
}
inline int use_k(Q &q) {
    const Q &c = q;
    return q.k() * 100 + c.k();
}
inline int use_p(Q &q) {
    const Q &c = q;
    return q.p(1) * 1000 + c.p(2);
}
inline int use_d(Q &q) { return q.d(1) * 10000 + q.d(2.5) * 100 + q.d_double(); }
inline int use_pick(const Q &q) { return q.pick().v(); }
} // namespace d4
