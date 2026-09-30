/* A small C header for the C interop page (site/src/content/docs/interop/c.md) */
#pragma once

#define VEC2_VERSION 3
#define VEC2_EPSILON 0.001

typedef struct {
    double x, y;
} vec2;

enum axis { AXIS_X, AXIS_Y };

static inline vec2 vec2_add(vec2 a, vec2 b) {
    vec2 r = {a.x + b.x, a.y + b.y};
    return r;
}

static inline double vec2_dot(const vec2 *a, const vec2 *b) {
    return a->x * b->x + a->y * b->y;
}

/* calls back into the program for each component */
static inline void vec2_each(vec2 v, void (*f)(double)) {
    f(v.x);
    f(v.y);
}
