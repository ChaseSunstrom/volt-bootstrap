// virtual methods with types Volt has no form for (cpp_derive5.volt): a parameter the override gets
// as a void* to C++'s argument, and a pure virtual whose result has no form, which doesn't keep
// Volt types from deriving (C++'s call of it throws)
#pragma once

namespace d5 {
struct Shape {
    int w = 3;
    virtual ~Shape() {}
    virtual int area() const = 0;
    virtual int pick(int Shape::*pm) const { return this->*pm; }
    virtual int Shape::*which() const = 0;
};
inline int used(const Shape &s) { return s.area() * 100 + s.pick(&Shape::w); }
inline int ask(const Shape &s) { return s.*(s.which()); }
}
