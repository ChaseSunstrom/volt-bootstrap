// Written for C++98: std::auto_ptr, a dynamic exception specification and the register keyword, all
// removed in C++17
#pragma once
#include <memory>
namespace v98 {
inline int old_sum(int a, int b) throw() {
    register int s = a + b;
    return s;
}
inline int owned_value(int x) throw(int) {
    std::auto_ptr<int> p(new int(x));
    return *p * 2;
}
}
