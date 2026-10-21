// What Volt's generics can't declare, called per use (cpp_templates.volt): variadic templates,
// non-type template parameters, auto results that hang on a template's types, constrained templates,
// function-like macros and method templates with several explicit arguments
#pragma once
#include <concepts>
#include <cstddef>

#define SQUARE(x) ((x) * (x))
#define PICK(c, a, b) ((c) ? (a) : (b))

namespace tpl {

struct Point {
    int x, y;
};

template <class... A>
auto sum(A... a) { return (a + ... + 0); }

template <class... A>
std::size_t count_args(A...) { return sizeof...(A); }

template <int N>
int times(int x) { return x * N; }

template <class T>
auto doubled(T x) { return x + x; }

template <class T>
    requires std::integral<T>
T twice(T x) { return x * 2; }

template <class T>
auto origin_of(T scale) { return Point{ int(scale), int(scale) * 2 }; }

struct Conv {
    int k = 2;
    template <class A, class B>
    B convert(A a) const { return B(a) * k; }
    template <class... A>
    int all(A... a) const { return (int(a) + ... + 0) * k; }
};

// class templates with a value parameter: Volt generics with one (<T: type, N: i32>), laid out when
// Volt can (fixed: T data[N]) and held by handle otherwise (counter's private state)
template <class T, int N> struct fixed {
    T data[N];
    T sum() const {
        T s = 0;
        for (int i = 0; i < N; i++) s += data[i];
        return s;
    }
    void add(int k) {
        for (int i = 0; i < N; i++) data[i] += k;
    }
    void add(double k) {
        for (int i = 0; i < N; i++) data[i] += (T)k;
    }
};
template <int N> class counter {
    int n_ = 0;
  public:
    int bump() {
        n_ += N;
        return n_;
    }
};
// a bool value parameter; functions with an instance that has a value argument (held by handle)
template <class T, bool Neg> struct sign {
    T v;
    T get() const { return Neg ? -v : v; }
};
template <bool B> int pick_if(int a, int b) { return B ? a : b; }
// a class template deriving from a base, held by handle (it has a private member): its as_named()
// gives the base, as a plain class's handle does
struct named {
    int tag() const { return 7; }
};
template <int N> class tally : public named {
    int n_ = N;
  public:
    int get() const { return n_; }
};
inline int total(const fixed<int, 3> &f) { return f.sum(); }
inline fixed<int, 3> threes() { return fixed<int, 3>{{3, 3, 3}}; }

} // namespace tpl
