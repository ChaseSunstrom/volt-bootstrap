// Written for C++98: std::auto_ptr, a dynamic exception specification and the register keyword, all
// removed in C++17; and a class with virtual methods, held by handle
#pragma once
#include <memory>
#include <string>
namespace v98 {
inline int old_sum(int a, int b) throw() {
    register int s = a + b;
    return s;
}
inline int owned_value(int x) throw(int) {
    std::auto_ptr<int> p(new int(x));
    return *p * 2;
}
class Shape {
  public:
    Shape() : name_("shape") {}
    virtual ~Shape() {}
    virtual int sides() const { return 0; }

  private:
    std::string name_;
};
inline int count_sides(const Shape &s) { return s.sides(); }
}
