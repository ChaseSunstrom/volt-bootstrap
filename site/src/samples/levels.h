/* A named enum, a long double and a _Complex, for the C interop page (site/src/content/docs/interop/c.md) */
#pragma once

enum level { LEVEL_LOW, LEVEL_HIGH = 10 };

static inline enum level level_up(enum level l) {
    return l == LEVEL_LOW ? LEVEL_HIGH : l;
}

static inline long double gain(long double x) {
    return x * 1.5L;
}

/* z times i: a quarter turn */
static inline double _Complex turn(double _Complex z) {
    return z * __builtin_complex(0.0, 1.0);
}
