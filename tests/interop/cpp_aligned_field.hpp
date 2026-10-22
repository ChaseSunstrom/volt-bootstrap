// classes whose layout comes from an aligned typedef's field: one aligned past its int (16), one
// below it (2, so its field sits at offset 2), and a packed one; the field's own int type doesn't
// give any of these layouts
#pragma once
#include <cstdint>

namespace af {
typedef int aint __attribute__((aligned(16)));
typedef int pint __attribute__((aligned(2)));

struct cell {
    char c;
    aint x;
    bool aligned() const { return ((std::uintptr_t)this % 16) == 0; }
    int read_x() const { return x; }
};

struct tight {
    char c;
    pint x;
};

// aligned as its double (8), as Volt would align it, but its int at offset 2, where Volt's wouldn't be
struct mixed {
    char c;
    pint x;
    double d;
};

// packed: its int at offset 1
struct __attribute__((packed)) squeezed {
    char c;
    int x;
};

// class templates laid out by an aligned typedef's field and by alignas on the class: held by
// handle too, not Volt generic structs (T-0632)
template <class T>
struct tcell {
    T c;
    aint x;
};
template <class T>
inline int tcell_x(const tcell<T> &v) { return v.x; }
template <class T>
struct alignas(32) twide {
    T x;
};
template <class T>
inline int twide_x(const twide<T> &v) { return (int)v.x + (int)sizeof(twide<T>); }

inline int squeezed_x(const squeezed &v) { return v.x; }
inline int squeezed_size() { return (int)sizeof(squeezed); }
inline int tight_x(const tight &v) { return v.x; }
inline int mixed_x(const mixed &v) { return v.x; }
inline int cell_size() { return (int)sizeof(cell); }
// (below C++17 cell is left out, and this has no wrapper, only a call per use: the rest of the
// header still imports)
inline int cell_x(const cell &v) { return v.x; }
inline int tight_size() { return (int)sizeof(tight); }
}
