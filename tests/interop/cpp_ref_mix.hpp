// parameters of one call wanting a T& and a T*: a call worked out per use (each takes a default
// argument of a type with no Volt form) reads each Volt reference the way its parameter takes it
#pragma once
#include <vector>

namespace rm {
typedef std::vector<std::vector<bool> > skips;
inline void mix(int &a, int *b, const skips & = skips()) { a += 10; *b += 20; }
inline void mix(double &a, double *b, const skips & = skips()) { a += 0.5; *b += 1.5; }
inline void swap_in(int *a, int &b, const skips & = skips()) { int t = *a; *a = b; b = t; }
inline void swap_in(double *a, double &b, const skips & = skips()) { double t = *a; *a = b; b = t; }
// both: f(&x) calls the T& one
inline int pick(int &, const skips & = skips()) { return 1; }
inline int pick(int *, const skips & = skips()) { return 2; }
inline int pick(double &, const skips & = skips()) { return 3; }
inline int pick(double *, const skips & = skips()) { return 4; }
}
