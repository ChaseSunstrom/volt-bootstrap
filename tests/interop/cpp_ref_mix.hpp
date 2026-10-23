// parameters of one call wanting a T& and a T*: a call worked out per use reads each Volt reference
// the way its parameter takes it
#pragma once

namespace rm {
inline void mix(int &a, int *b) { a += 10; *b += 20; }
inline void mix(double &a, double *b) { a += 0.5; *b += 1.5; }
inline void swap_in(int *a, int &b) { int t = *a; *a = b; b = t; }
inline void swap_in(double *a, double &b) { double t = *a; *a = b; b = t; }
// both: f(&x) calls the T& one
inline int pick(int &) { return 1; }
inline int pick(int *) { return 2; }
inline int pick(double &) { return 3; }
inline int pick(double *) { return 4; }
}
