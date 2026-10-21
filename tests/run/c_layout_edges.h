#pragma once
#include <stddef.h>
/* a packed struct holding a 32-byte vector, and scalars after a char: read and written in place */
struct __attribute__((packed)) pk {
    char c;
    int v __attribute__((vector_size(32)));
    double d;
    int s;
};
static inline size_t pk_size(void) { return sizeof(struct pk); }
static inline size_t pk_off_v(void) { return offsetof(struct pk, v); }
static inline int pk_sum(const struct pk *p) {
    int t = p->c + p->s + (int)p->d;
    for (int i = 0; i < 8; i++) t += p->v[i];
    return t;
}
static inline void pk_fill(struct pk *p) {
    p->c = 1;
    p->s = 2;
    p->d = 3.0;
    for (int i = 0; i < 8; i++) p->v[i] = 10 * i;
}
/* a union holding a 32-byte vector, in a struct: at C's offset (16 on AArch64, 32 on x86-64) */
union uv { int v __attribute__((vector_size(32))); char b; };
struct su { char c; union uv u; };
static inline size_t su_off_u(void) { return offsetof(struct su, u); }
static inline size_t su_size(void) { return sizeof(struct su); }
static inline int su_get(const struct su *s) { return s->u.v[7]; }
/* a header struct aligned past 16, taken by value by a Volt fn */
struct __attribute__((aligned(32))) a32 { int x[5]; };
static inline size_t a32_size(void) { return sizeof(struct a32); }
/* attributes and #pragma pack: C's sizes and offsets, not Volt's own layout of the fields */
struct __attribute__((packed)) p1 { char c; int x; };
struct __attribute__((aligned(8))) a8 { int x; };
struct m1 { char c; int x __attribute__((aligned(16))); };
#pragma pack(push, 1)
struct pp { char c; int x; short y; };
#pragma pack(pop)
static inline size_t p1_size(void) { return sizeof(struct p1); }
static inline size_t a8_size(void) { return sizeof(struct a8); }
static inline size_t m1_size(void) { return sizeof(struct m1); }
static inline size_t pp_size(void) { return sizeof(struct pp); }
/* a packed struct by value: SysV passes one with an unaligned field in memory */
static inline int p1_take(struct p1 a) { return a.c + a.x; }
static inline struct p1 p1_make(int x) { struct p1 a = { 7, x }; return a; }
static inline int attr_sum(const struct p1 *a, const struct a8 *b, const struct m1 *m, const struct pp *p) {
    return a->c + a->x + b->x + m->c + m->x + p->c + p->x + p->y;
}
