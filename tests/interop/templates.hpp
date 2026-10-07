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

} // namespace tpl
