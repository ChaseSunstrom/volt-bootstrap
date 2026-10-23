// conversion operators in a class template (cpp_template_conv.volt): one to the template's own
// parameter (to_T()) and one whose type doesn't depend on it (to_bool())
#pragma once

namespace tc {
template <class T>
struct Box {
    T v;
    operator T() const { return v; }
    explicit operator bool() const { return v != T(); }
};

inline Box<int> box_int(int v) { return Box<int>{v}; }
inline Box<double> box_double(double v) { return Box<double>{v}; }
}
