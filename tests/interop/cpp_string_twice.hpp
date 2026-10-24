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
// a const std::string& given the same string as a std::string&: one string, so the write shows
// through the const one, in either order
inline std::string seen(std::string &a, const std::string &b) {
    a += "!";
    return b;
}
inline std::string seen2(const std::string &b, std::string &a) {
    a += "?";
    return b;
}
}
