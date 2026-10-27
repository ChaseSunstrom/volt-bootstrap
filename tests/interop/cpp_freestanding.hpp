// C++ with no standard library and no exceptions (built with -nostdinc++ -fno-exceptions): a class
// with a constructor, methods and a destructor, a template, an enum class, overloads, a callback by
// function pointer and one by template, a struct by value, a namespace's global
#pragma once

namespace bare {

struct vec2 {
    int x;
    int y;
};

inline vec2 add(vec2 a, vec2 b) { return vec2{a.x + b.x, a.y + b.y}; }

class counter {
public:
    explicit counter(int start) : n_(start) { ++live; }
    ~counter() { --live; }
    void bump(int by) { n_ += by; }
    void bump() { n_ += 1; }
    int get() const { return n_; }
    static int live;

private:
    int n_;
};

inline int counter::live = 0;

template <class T>
T twice(T x) { return x + x; }

enum class color { red, green, blue };

inline int live_count() { return counter::live; }

inline int code(color c) { return c == color::blue ? 3 : c == color::green ? 2 : 1; }

inline int apply(int (*f)(int), int x) { return f(x); }

template <class F>
int call_with(F f, int x) { return f(x) + 1; }

} // namespace bare
