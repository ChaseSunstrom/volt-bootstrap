/* what has no type until it's used: function-like macros, a va_list function, varargs ones
   giving or taking a long double, and a _Complex one */
#include <stdarg.h>

struct pt { int x, y; };

#define MAX(a, b) ((a) > (b) ? (a) : (b))
#define SQUARE(x) ((x) * (x))
#define PT_SUM(p) ((p)->x + (p)->y)
#define HALF_LD(x) ((long double)(x) / 2)
#define BUMP(p) (++(p)->x)
#define FIRST_PT(ps) (&(ps)[0])
/* what C does with its argument itself: changes it, sizes it, spells it */
#define INC(x) (++(x))
#define LEN(s) (sizeof(s) - 1)
#define NAME_OF(x) #x
/* an enum, a struct by value, a pointer and a char back */
enum color { RED, GREEN = 5 };
#define COLOR_AFTER(c) ((enum color)((c) + 5))
#define PT_TOTAL(p) ((p).x + (p).y)
#define X_OF(p) (&(p)->x)
#define FIRST_CHAR(s) ((s)[0])
#define ANON() ((struct { int a; }){1})
/* a long, which Volt's i64 is too */
static inline int read_long(long *p) { return (int)*p; }
#define READ_LONG(p) read_long(p)
/* a va_list with nothing before it: va_start needs a parameter before C23, so it isn't imported */
static inline int vonly(va_list ap) { return va_arg(ap, int); }

static inline int vsum(int n, va_list ap) {
    int s = 0;
    for (int i = 0; i < n; i++) s += va_arg(ap, int);
    return s;
}
static inline void vscale(struct pt *p, int k, va_list ap) {
    p->x = k * va_arg(ap, int);
    p->y = k * va_arg(ap, int);
}
static inline long double ldsum(int n, ...) {
    va_list ap;
    va_start(ap, n);
    long double s = 0;
    for (int i = 0; i < n; i++) s += va_arg(ap, double);
    va_end(ap);
    return s;
}
static inline int ldcount(long double base, ...) {
    va_list ap;
    va_start(ap, base);
    int n = 0;
    while (va_arg(ap, int) != 0) n++;
    va_end(ap);
    return n + (int)base;
}
static inline double _Complex cmake(int n, ...) {
    va_list ap;
    va_start(ap, n);
    double re = va_arg(ap, double);
    double im = n > 1 ? va_arg(ap, double) : 0;
    va_end(ap);
    return re + im * 1.0i;
}
