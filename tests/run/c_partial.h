/* structs with members Volt can't read (a bitfield, a _Complex, a long double), for
   tests/run/c_partial.volt: libclang places the fields Volt reads, and C passes them by value */
#include <stddef.h>

/* a bitfield, a union member and a _Complex around fields Volt reads: 32 bytes */
struct sample {
    int id;
    unsigned ready : 1;
    unsigned level : 3;
    union { int code; float ratio; } u;
    _Complex float z;
    double weight;
};

/* 12 bytes: C passes it in two SSE registers (the _Complex's floats), not as integers */
struct pair {
    float x;
    _Complex float z;
};

/* 20 bytes, aligned to 4: bitfields after an int */
struct five {
    int a;
    unsigned x : 32;
    unsigned y : 32;
    unsigned z : 32;
    unsigned w : 32;
};

/* aligned to 16 by a member Volt can't read */
struct wide {
    int a;
    long double x;
};

static inline size_t sample_size(void) { return sizeof(struct sample); }
static inline size_t sample_align(void) { return _Alignof(struct sample); }
static inline size_t pair_size(void) { return sizeof(struct pair); }
static inline size_t five_size(void) { return sizeof(struct five); }
static inline size_t five_align(void) { return _Alignof(struct five); }
static inline size_t wide_size(void) { return sizeof(struct wide); }
static inline size_t wide_align(void) { return _Alignof(struct wide); }

static inline struct sample sample_make(int id, float re) {
    struct sample s = { 0 };
    s.id = id;
    s.ready = 1;
    s.level = 5;
    s.u.code = 7;
    s.z = __builtin_complex(re, 2.0f);
    s.weight = 0.5;
    return s;
}
/* every member, read by C */
static inline double sample_total(struct sample s) {
    return s.id + s.ready + s.level + s.u.code + __real__ s.z + __imag__ s.z + s.weight;
}
static inline struct sample sample_next(struct sample s) {
    s.id += 1;
    s.level += 1;
    s.z *= 2;
    s.weight *= 2;
    return s;
}

static inline struct pair pair_make(float x) {
    struct pair p;
    p.x = x;
    p.z = __builtin_complex(x * 2, x * 3);
    return p;
}
static inline float pair_sum(struct pair p) { return p.x + __real__ p.z + __imag__ p.z; }
static inline struct pair pair_scale(struct pair p, int k) {
    p.x *= k;
    p.z *= k;
    return p;
}

/* an array of them: C's stride */
static inline int five_sum(const struct five *f, int n) {
    int t = 0;
    for (int i = 0; i < n; i++) {
        t += f[i].a + f[i].w;
    }
    return t;
}

static inline struct wide wide_make(int a) {
    struct wide w;
    w.a = a;
    w.x = a * 1.5L;
    return w;
}
static inline double wide_get(struct wide w) { return w.a + (double)w.x; }

/* a call through a C function pointer, and a Volt fn C calls by one */
typedef float (*pair_fn)(struct pair);
static inline pair_fn pair_summer(void) { return pair_sum; }
static inline float pair_apply(pair_fn f, struct pair p) { return f(p); }
