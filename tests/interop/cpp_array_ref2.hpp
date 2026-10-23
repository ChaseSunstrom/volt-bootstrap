// a const std::string_view(&)[N] parameter takes a Volt str[N]; a T(&)[N] result of an enum is a
// Volt T[N]& into C++'s array, of a class Volt holds by handle a T[N] of handles borrowing its
// elements (cpp_array_ref2.volt)
#pragma once
#include <cstddef>
#include <string>
#include <string_view>
namespace arr2 {
enum class Mode : int { A, B, C };
// (a std::string field: held by handle)
struct Widget {
    int n;
    std::string tag;
    Widget(int v) : n(v), tag("w") {}
    int get() const { return n; }
    void set(int v) { n = v; }
};
inline std::size_t total_len(const std::string_view (&s)[2]) { return s[0].size() + s[1].size(); }
inline std::string join(const std::string_view (&s)[2]) { return std::string(s[0]) + "+" + std::string(s[1]); }
inline Mode (&modes())[3] {
    static Mode m[3] = {Mode::A, Mode::B, Mode::C};
    return m;
}
inline int mode_at(int i) { return (int)modes()[i]; }
inline Widget (&widgets())[2] {
    static Widget w[2] = {Widget(1), Widget(2)};
    return w;
}
inline int widget_at(int i) { return widgets()[i].n; }
}
