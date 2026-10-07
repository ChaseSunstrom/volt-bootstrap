/* Function-like macros and a va_list function, for the C interop page (site/src/content/docs/interop/c.md) */
#pragma once
#include <stdarg.h>

struct box { int w, h; };

#define AREA(b) ((b)->w * (b)->h)
#define CLAMP(x, lo, hi) ((x) < (lo) ? (lo) : (x) > (hi) ? (hi) : (x))

/* the sum of n ints */
static inline int vtotal(int n, va_list ap) {
    int s = 0;
    for (int i = 0; i < n; i++) s += va_arg(ap, int);
    return s;
}
