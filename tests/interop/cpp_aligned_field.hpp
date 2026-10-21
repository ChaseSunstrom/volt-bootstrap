// classes whose layout comes from an aligned typedef's field: one aligned past its int (16), one
// below it (2, so its field sits at offset 2); the field's own int type doesn't give either layout
#pragma once
#include <cstdint>

namespace af {
typedef int aint __attribute__((aligned(16)));
typedef int pint __attribute__((aligned(2)));

struct cell {
    char c;
    aint x;
    bool aligned() const { return ((std::uintptr_t)this % 16) == 0; }
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

inline int cell_x(const cell &v) { return v.x; }
inline int tight_x(const tight &v) { return v.x; }
inline int mixed_x(const mixed &v) { return v.x; }
inline int cell_size() { return (int)sizeof(cell); }
inline int tight_size() { return (int)sizeof(tight); }
inline int mixed_size() { return (int)sizeof(mixed); }
}
