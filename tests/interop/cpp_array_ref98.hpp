// T(&)[N] parameters copied in, read as C++98 too (cpp_array_ref98.volt): std::vector's push_back
// assigns its elements there, so a const T(&)[N] of a class that's copied but not assigned (Pin) has
// a Volt form only from C++11 on; one that's assigned too (Box) has both forms in any standard
#pragma once
#include <string>
namespace ar98 {
struct Box {
    std::string name;
    int size;
    Box(const std::string &n, int s) : name(n), size(s) {}
    int get() const { return size; }
};
inline int total(const Box (&b)[2]) { return b[0].size + b[1].size; }
inline void grow(Box (&b)[2], int by) {
    for (int i = 0; i < 2; i++) {
        b[i].size += by;
        b[i].name += "+";
    }
}
inline int lengths(const std::string (&s)[2]) { return (int)(s[0].size() + s[1].size()); }
inline void append(std::string (&s)[2], const std::string &t) {
    s[0] += t;
    s[1] += t;
}
// (not assigned as C++98 says it: an assignment that's private, and never defined)
struct Pin {
    int id;
    std::string tag;
    Pin(int i) : id(i) {}
    int get() const { return id; }

private:
    Pin &operator=(const Pin &);
};
inline int pin_sum(const Pin (&p)[2]) { return p[0].id + p[1].id; }
}
