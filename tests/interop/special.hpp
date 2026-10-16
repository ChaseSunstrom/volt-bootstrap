// Explicit and partial specializations, and what a library adds to namespace std
// (cpp_special_class.volt, cpp_special_fn.volt, cpp_special_std.volt)
#pragma once
#include <cstddef>
#include <functional>
#include <unordered_map>  // (for std::unordered_map<sp::Key, int> in Volt)

namespace sp {

// a class template Volt lays out; its specializations have other fields than the primary's
template <class T>
struct box {
    T v;
    int tag;
    int get_tag() const { return tag; }
};

// an explicit specialization: its own fields, constructor and method
template <>
struct box<void> {
    double scale;
    explicit box(double s) : scale(s) {}
    double scaled(double x) const { return x * scale; }
};

// a partial specialization: a box of a pointer
template <class T>
struct box<T*> {
    T* p;
    int hits;
    explicit box(T* q) : p(q), hits(0) {}
    T deref() { hits += 1; return *p; }
};

inline int box_int_size() { return int(sizeof(box<int>)); }
// a specialization in a signature: the import's handle, as Volt's box<void> is
inline double void_twice(const box<void>& b) { return b.scaled(2.0); }

// function templates with explicit specializations: C++ picks the specialization (the primary's
// result tells them apart)
template <class T>
int pick(T) { return 1; }
template <>
inline int pick<int>(int) { return 2; }

struct Meter {
    int base;
    template <class T>
    int unit(T) const { return base + 10; }
};
template <>
inline int Meter::unit<double>(double) const { return base + 20; }

// a key: std::hash<Key> (below, in namespace std) keys a std::unordered_map, and a swap found by
// argument-dependent lookup, which marks that it ran
struct Key {
    int id;
    bool operator==(const Key& o) const { return id == o.id; }
};
inline void swap(Key& a, Key& b) {
    int t = a.id;
    a.id = b.id + 100;
    b.id = t + 100;
}

}  // namespace sp

namespace std {
template <>
struct hash<sp::Key> {
    std::size_t operator()(const sp::Key& k) const { return std::size_t(k.id) * 7u; }
};
}  // namespace std
