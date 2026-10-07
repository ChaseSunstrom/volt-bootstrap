// A header that imports the standard library as a module (import std;), for cpp_module.volt
#pragma once
import std;

namespace us {
inline int total(const std::vector<int> &v) {
    int s = 0;
    for (int x : v) s += x;
    return s;
}
inline std::string greet(std::string_view n) { return std::string("hi ") + std::string(n); }
// declared, defined nowhere: the program links because nothing calls it (only called wrappers are
// compiled)
int never_defined(int x);
}
