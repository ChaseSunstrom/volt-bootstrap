/* typedefs as Volt type names, for tests/run/c_typedefs.volt */
#include <stddef.h>

typedef unsigned long long big;
typedef int (*binop)(int, int);
struct counter { int n; };
typedef struct counter tally;           /* the struct's name in Volt */
typedef struct counter *counter_ref;    /* a pointer typedef */
typedef struct { binop op; big scale; } calc;

static inline int add2(int a, int b) { return a + b; }
static inline binop pick(int which) { return which ? add2 : 0; }
static inline void bump(counter_ref c) { c->n += 1; }
static inline big times(big a, big b) { return a * b; }
