/* struct shapes for the C calling convention (SysV x86-64): each takes a different path through
   registers or memory. c_abi.volt calls these and lets C call back into Volt. */
#include <stdint.h>
#include <stdarg.h>

typedef struct { int32_t a; int32_t b; } ii;       /* one INTEGER eightbyte */
typedef struct { int64_t a; int32_t b; } li;       /* INTEGER, INTEGER (a 4-byte tail) */
typedef struct { float x; float y; } ff;           /* one SSE eightbyte: two floats */
typedef struct { double x; int32_t n; } di;        /* SSE, INTEGER */
typedef struct { float x; float y; float z; } fff; /* SSE (two floats), SSE (one) */
typedef struct { int64_t a, b, c; } big;           /* over 16 bytes: memory */
typedef struct { char c; short s; } cs;            /* a 4-byte eightbyte with padding */
typedef struct { uint8_t bytes[5]; } five;         /* a 5-byte eightbyte */

static inline ii ii_add(ii p, ii q) { return (ii){ p.a + q.a, p.b + q.b }; }
static inline li li_mix(li p, int32_t k) { return (li){ p.a * k, p.b + k }; }
static inline ff ff_scale(ff p, float k) { return (ff){ p.x * k, p.y * k }; }
static inline di di_make(double x, int32_t n) { return (di){ x, n }; }
static inline double fff_sum(fff p) { return p.x + p.y + p.z; }
static inline fff fff_make(float v) { return (fff){ v, v * 2, v * 3 }; }
static inline big big_add(big p, big q) { return (big){ p.a + q.a, p.b + q.b, p.c + q.c }; }
static inline int32_t cs_sum(cs p) { return p.c + p.s; }
static inline five five_rev(five f) { five r; for (int i = 0; i < 5; i++) r.bytes[i] = f.bytes[4 - i]; return r; }
/* four li use eight INTEGER registers: the last ones go on the stack */
static inline int64_t many(li a, li b, li c, li d, int64_t e) { return a.a + b.a + c.a + d.a + d.b + e; }
static inline double mixed(double a, ff b, int32_t c, di d, float e) { return a + b.x + b.y + c + d.x + d.n + e; }
static inline uint8_t small_ints(int8_t a, uint8_t b, int16_t c, _Bool d) { return (uint8_t)(a + b + c + d); }
/* C calls back into Volt */
static inline int64_t apply(int64_t (*f)(li, int64_t), li p) { return f(p, 10); }
static inline double apply_ff(ff (*f)(ff, float), ff p) { ff r = f(p, 2.0f); return r.x + r.y; }
static inline big apply_big(big (*f)(big), big p) { return f(p); }
/* variadic: floats arrive as double, small ints as int */
static inline double sum_va(int n, ...) {
    va_list ap;
    va_start(ap, n);
    double t = 0;
    for (int i = 0; i < n; i++) t += va_arg(ap, double);
    va_end(ap);
    return t;
}
/* structs through `...`: small ones in registers, big ones copied onto the stack */
static inline int64_t va_structs(int n, ...) {
    va_list ap;
    va_start(ap, n);
    int64_t t = 0;
    for (int i = 0; i < n; i++) {
        ii p = va_arg(ap, ii);
        big q = va_arg(ap, big);
        t += p.a + p.b + q.a + q.b + q.c;
    }
    va_end(ap);
    return t;
}
