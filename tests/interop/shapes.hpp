// C++ that Volt imports with `use cpp { "shapes.hpp" } as shapes;` (tests/interop/cpp_import.volt)
#pragma once
#include <cstdio>
#include <stdexcept>

namespace geo {

enum class Kind { Circle = 1, Square = 4 };
enum Plain { ONE = 1, TWO = 2 };

class Shape {
public:
    Shape(int w, int h) : w(w), h(h) { std::printf("make %d %d\n", w, h); }
    explicit Shape(int side) : Shape(side, side) {}
    Shape(const Shape& o) : w(o.w), h(o.h) { std::printf("copy %d %d\n", w, h); }
    ~Shape() { std::printf("drop %d %d\n", w, h); }
    int area() const { return w * h; }
    void grow(int by = 1) { w += by; h += by; }
    int scaled(int k) const { return area() * k; }
    double scaled(double k) const { return area() * k; }
    static int count() { return 7; }
    Kind kind() const { return w == h ? Kind::Square : Kind::Circle; }
    const char* name() const { return w == h ? "square" : "rect"; }
    int checked(int x) const {
        if (x < 0) throw std::invalid_argument("negative");
        return x;
    }
    int w, h;

private:
    long secret = 99;
};

// overloads Volt can't tell apart (long and long long are both i64): it gets the first
inline int add(int a, int b) { return a + b; }
inline long add(long a, long b) { return a + b; }
inline long long add(long long a, long long b) { return a + b; }

// can't be copied (a member can't): Volt gets delete but no copy
struct Owner {
    Owner() {}
    ~Owner() {}
    struct NoCopy {
        NoCopy() {}
        NoCopy(const NoCopy &) = delete;
    } part;
};

#ifndef SHAPES_FLAG
#error "SHAPES_FLAG comes from --cc -D SHAPES_FLAG (two arguments)"
#endif
inline double add(double a, double b) { return a + b; }
inline int total(const Shape& a, const Shape& b) { return a.area() + b.area(); }
inline Shape square(int side) { return Shape(side); }

template <typename T>
T biggest(T a, T b) { return a > b ? a : b; }

template <typename T>
struct Box {
    T value;
    T get() const { return value; }
    void set(T v) { value = v; }
};

}  // namespace geo
