// class templates over an enum or a char value (cpp_value_params.volt): Volt generics over the
// enum's integer type or char's, C++ getting static_cast<E>(n) for an enum
#pragma once
#include <string>

namespace vp {
// (C++98 has neither scoped enums nor a fixed underlying type: plain ones there, unsigned int to Volt)
#if __cplusplus >= 201103L
enum class Mode : int { A, B, C };
enum Small : unsigned char { S0, S1, S7 = 7 };
#else
enum Mode { A, B, C };
enum Small { S0, S1, S7 = 7 };
#endif
template <Mode M> struct Tag {
    static int id() { return (int)M * 10; }
};
template <char C> struct Ch {
    static char get() { return C; }
    static int next() { return C + 1; }
};
// laid out by Volt, and held by handle (a std::string field)
template <class T, Mode M> struct Scale {
    T v;
    T scaled() const { return v * ((int)M + 1); }
};
template <Small S> struct Named {
    std::string name;
    Named() : name("n") {}
    int size() const { return (int)name.size() + (int)S; }
};
}
