// one string given to two std::string& parameters is one C++ string, as C++ passes it
// (cpp_string_twice.volt)
#pragma once
#include <string>

namespace st {
inline void both(std::string &a, std::string &b) { a += "x"; b += "y"; }
inline int three(std::string &a, int n, std::string &b, std::string &c) {
    a += "1";
    b += "2";
    c += "3";
    return n + int(a.size());
}
}
