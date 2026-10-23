// T(&)[N] parameters of any element: an enum by the Volt array's address (cpp_array_ref_enum.volt);
// a class Volt holds by handle (cpp_array_ref_handle.volt) and a std::string
// (cpp_array_ref_string.volt) through a C++ array the call makes from the Volt one, C++'s changes
// copied back once it returns (not when it threw); a class that can't be copied in (or back) has none
#pragma once
#include <cstdint>
#include <stdexcept>
#include <string>
namespace ar {
enum Color { RED, GREEN, BLUE };
enum class Level : std::uint8_t { LOW = 1, MID = 7, HIGH = 100 };
inline void rotate(Color (&c)[3]) {
    Color t = c[0];
    c[0] = c[1];
    c[1] = c[2];
    c[2] = t;
}
inline int level_sum(const Level (&l)[2]) { return (int)l[0] + (int)l[1]; }
inline void raise(Level (&l)[2]) {
    l[0] = Level::HIGH;
    l[1] = Level::MID;
}

// not trivially copyable (a std::string member): Volt holds it by handle
struct Widget {
    std::string name;
    int size;
    Widget(const std::string &n, int s) : name(n), size(s) {}
    int get() const { return size; }
    std::string label() const { return name; }
};
inline void grow(Widget (&w)[2], int by) {
    for (Widget &x : w) {
        x.size += by;
        x.name += "+";
    }
}
inline int total(const Widget (&w)[2]) { return w[0].size + w[1].size; }
// changes them, then throws when by is negative: the Volt handles keep their objects as they were
inline void grow_or_throw(Widget (&w)[2], int by) {
    grow(w, by);
    if (by < 0) throw std::invalid_argument("negative");
}

inline void append(std::string (&s)[2], const std::string &t) {
    for (std::string &x : s) x += t;
}
inline void append_or_throw(std::string (&s)[2], int n) {
    append(s, "!");
    if (n < 0) throw std::invalid_argument("negative");
}
inline int lengths(const std::string (&s)[2]) { return (int)(s[0].size() + s[1].size()); }

// copied, not assigned (a const member): its const T(&)[N] has a Volt form, its T(&)[N] none
struct Pin {
    const int id;
    std::string tag;
    Pin(int i) : id(i) {}
    int get() const { return id; }
};
inline int pin_sum(const Pin (&p)[2]) { return p[0].id + p[1].id; }
inline void pin_touch(Pin (&p)[2]) { p[0].tag = "x"; }
// neither copied nor moved: no Volt form either way
struct Lock {
    int id;
    std::string owner;
    Lock() : id(0) {}
    Lock(const Lock &) = delete;
    Lock &operator=(const Lock &) = delete;
};
inline int lock_sum(const Lock (&l)[2]) { return l[0].id + l[1].id; }
inline void lock_touch(Lock (&l)[2]) { l[0].id = 1; }
}
