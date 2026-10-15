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
}
