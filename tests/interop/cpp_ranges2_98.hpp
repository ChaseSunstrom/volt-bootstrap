// A std::map from a header read under C++98, where a range has no decltype or std::begin to go by
// (cpp_ranges2.volt)
#pragma once
#include <map>

namespace r98 {
inline std::map<int, int> table() {
    std::map<int, int> m;
    m[2] = 20;
    m[1] = 10;
    return m;
}
// a const std::map& under C++98: a Volt std::map's entries copied in, or the handle table() gave
inline int total(const std::map<int, int> &m) {
    int t = 0;
    for (std::map<int, int>::const_iterator i = m.begin(); i != m.end(); ++i) {
        t += i->first * i->second;
    }
    return t;
}
}
