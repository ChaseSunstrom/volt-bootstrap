// std::functions whose signature has a non-const reference, a class Volt holds by handle or gives
// one back (cpp_fn_refs.volt): a Volt closure, C++ seeing what it changes
#pragma once
#include <functional>
#include <string>

namespace fr {
// held by handle (a std::string member)
class Shape {
  public:
    Shape(const char *n, int side) : name_(n), side_(side) {}
    int area() const { return side_ * side_; }
    std::string name() const { return name_; }
    void rename(const char *n) { name_ = n; }
  private:
    std::string name_;
    int side_;
};
struct cell { int x; int y; };

inline std::string shout(const char *s, const std::function<void(std::string &)> &f) {
    std::string t(s);
    f(t);
    return t;
}
inline int measure(const std::function<int(const Shape &)> &f) { Shape s("sq", 3); return f(s); }
inline std::string made(const std::function<Shape(int)> &f) {
    Shape s = f(4);
    return s.name() + ":" + std::to_string(s.area());
}
inline int twice_in(const std::function<void(int &)> &f) { int x = 5; f(x); f(x); return x; }
inline std::string renamed(const std::function<void(Shape &)> &f) { Shape s("a", 1); f(s); return s.name(); }
inline int moved(const std::function<void(cell &)> &f) { cell c = {1, 2}; f(c); return c.x * 10 + c.y; }
inline int taken(const std::function<int(std::string &&)> &f) { return f(std::string("four")); }
}
