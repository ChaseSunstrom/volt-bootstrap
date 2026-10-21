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
/* the attribute among the specifiers (every declarator's), a size in parens, and one voltc can't
   read (4 * sizeof(float): the struct is partial, laid out by libclang) */
struct vm { __attribute__((vector_size(16))) int a, b; float c __attribute__((vector_size((8)))); };
struct vx { int t; float d __attribute__((vector_size(4 * sizeof(float)))); };
static inline size_t vm_size(void) { return sizeof(struct vm); }
static inline size_t vx_size(void) { return sizeof(struct vx); }
static inline int vm_sum(const struct vm *m) { return m->a[0] + m->b[3] + (int)m->c[1]; }
/* by value: a 16-byte vector, and a struct holding one (C passes it in a vector register) */
struct w1 { v4f f; };
static inline float v4f_sum(v4f x) { return x[0] + x[1] + x[2] + x[3]; }
static inline float w1_get(struct w1 w) { return w.f[1]; }
