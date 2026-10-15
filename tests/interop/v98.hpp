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
    // overloads Volt can't tell apart, called exactly under C++98 too
    int tag() const { return 1; }
    int tag() { return 2; }

  private:
    std::string name_;
};
inline int count_sides(const Shape &s) { return s.sides(); }
// char last, so it collides whatever char's signedness (signed on x86-64, unsigned on arm64 Linux)
inline int pick(signed char) { return 2; }
inline int pick(unsigned char) { return 3; }
inline int pick(char) { return 1; }
}
