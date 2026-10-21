#pragma once
#include <stddef.h>
/* members declared with vector_size: Volt sees @vector(T, n), laid out as C lays them out */
typedef float v4f __attribute__((vector_size(16)));
struct vs {
    int tag;
    int v __attribute__((vector_size(32)));
    v4f f;
};
static inline size_t vs_size(void) { return sizeof(struct vs); }
static inline size_t vs_off_v(void) { return offsetof(struct vs, v); }
static inline size_t vs_off_f(void) { return offsetof(struct vs, f); }
static inline int vs_sum(const struct vs *s) {
    int t = s->tag;
    for (int i = 0; i < 8; i++) t += s->v[i];
    for (int i = 0; i < 4; i++) t += (int)s->f[i];
    return t;
}
/* a vector of a type Volt has no vector of: the struct is partial (libclang's layout) */
typedef __int128 v2q __attribute__((vector_size(16)));
struct vq { int t; v2q v; };
static inline size_t vq_size(void) { return sizeof(struct vq); }
