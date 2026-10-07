// Subclassing a C++ class from Volt (cpp_derive2.volt): overrides taking std::map, a class held by
// handle, a std::function, a std::vector to fill and a T&&, and giving back a std::map; copies of
// derived objects; casts and type names without RTTI; a base whose destructor isn't virtual
#pragma once
#include <functional>
#include <map>
#include <memory>
#include <string>
#include <vector>

namespace dv {
class Item {
  public:
    explicit Item(int v) : v_(v) {}
    Item(const Item &) = default;
    int v() const { return v_; }

  private:
    int v_;
    std::string tag_ = "item";
};

class Base {
  public:
    virtual int total(const std::map<int, int> &m) = 0;
    virtual int weigh(const Item &it) { return it.v(); }
    virtual int run(const std::function<int(int)> &f) { return f(1); }
    virtual std::map<int, int> table(int n) { return {}; }
    virtual void fill(std::vector<int> &v) {}
    virtual int sink(Item &&it) { return 0; }
    int tag = 7;
    ~Base() = default; // not virtual
};

class Mid : public Base {
  public:
    int total(const std::map<int, int> &) override { return -1; }
};

inline int use_total(Base &b) {
    std::map<int, int> m{{1, 10}, {2, 20}};
    return b.total(m);
}
inline int use_weigh(Base &b) { return b.weigh(Item(5)); }
inline int use_run(Base &b) {
    return b.run([](int x) { return x * 100; });
}
inline int use_fill(Base &b) {
    std::vector<int> v{1};
    b.fill(v);
    int s = 0;
    for (int x : v) s += x;
    return s;
}
inline int use_sink(Base &b) { return b.sink(Item(9)); }
// a std::map with another order: not stdcxx::map<i32, i32> (that's std::less's)
inline std::map<int, int, std::greater<int>> desc() { return {{1, 1}, {5, 5}, {3, 3}}; }
inline int top(const std::map<int, int, std::greater<int>> &m) { return m.begin()->first; }
// a derived object back from C++: borrowed, and owned (Volt deletes it)
inline Base &same(Base &b) { return b; }
inline std::unique_ptr<Base> pass(std::unique_ptr<Base> p) { return p; }
inline int use_table(Base &b) {
    int s = 0;
    for (auto &kv : b.table(3)) s += kv.first * kv.second;
    return s;
}
}
