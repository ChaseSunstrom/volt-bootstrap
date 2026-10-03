// C++ that Volt imports with `use cpp { "shapes.hpp" } as shapes;` (tests/interop/cpp_import.volt)
#pragma once
#include <cstdio>
#include <stdexcept>
#include <string>

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

// trivially copyable: Volt holds it by value, with C++'s layout
struct Size {
    int w, h;
    long area;
};

// points into itself: a byte copy would leave it pointing at the old place (Volt holds it by handle,
// so it never moves)
class Ring {
public:
    Ring() : self(this) {}
    Ring(const Ring&) : self(this) {}
    bool intact() const { return self == this; }

private:
    Ring* self;
};

// a std::string member (libstdc++'s points into itself too) and public fields: getters and set_
struct Named {
    std::string name = "a name long enough to live on the heap, not in the string itself";
    int n = 1;
    Size size{2, 3, 6};
    std::string label() const { return name + "#" + std::to_string(n); }
};
inline Named named(int n) {
    Named x;
    x.n = n;
    return x;
}
inline int ring_ok(const Ring& r) { return r.intact() ? 1 : 0; }

// abstract: Shelf::first's const& result can't be copied out, so it's left out (not new Solid(...))
struct Solid {
    virtual ~Solid() = default;
    virtual int volume() const = 0;
};
struct Cube : Solid {
    int side = 2;
    int volume() const override { return side * side * side; }
};
struct Shelf {
    Cube cube;
    const Solid& first() const { return cube; }
    int volume() const { return first().volume(); }
};

// a field that can't be assigned (Id's const member): a getter, no set_; and a set_x of its own,
// which Volt calls instead of writing one
struct Id {
    const int v;
};
struct Record {
    Id id{7};
    std::string tag = "r";
    int x = 1;
    void set_x(int v) { x = v * 10; }
};

// a field held by handle in a class template: Volt can't lay it out, so the template is left out
template <class T>
struct Holder {
    Named n;
    T v;
};

// parameters named as the generated locals once were
inline std::string echo(int r, int out) { return std::to_string(r) + "/" + std::to_string(out); }

// a destructor that isn't public: Volt can't own one, so only its static methods come through
class Registry {
    ~Registry() = default;
    std::string name;

public:
    static int size() { return 3; }
};

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
