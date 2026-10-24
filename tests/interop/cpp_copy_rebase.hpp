// results pointing into the copy Volt makes for a parameter (a std::string of a str, a std::vector of
// a slice): moved to the same place in the Volt memory the copy was made from (cpp_copy_rebase.volt)
#pragma once
#include <string>
#include <string_view>
#include <vector>

namespace cr {
inline std::string_view trim(const std::string &s) {
    size_t a = s.find_first_not_of(' ');
    if (a == std::string::npos) {
        return std::string_view();
    }
    size_t b = s.find_last_not_of(' ');
    return std::string_view(s).substr(a, b - a + 1);
}
inline const int *biggest(const std::vector<int> &v) {
    const int *m = v.empty() ? nullptr : &v[0];
    for (const int &x : v) {
        if (x > *m) {
            m = &x;
        }
    }
    return m;
}
struct pt { int x; int y; };
inline const pt &leftmost(const std::vector<pt> &v) {
    const pt *m = &v[0];
    for (const pt &p : v) {
        if (p.x < m->x) {
            m = &p;
        }
    }
    return *m;
}
}
