/* function-like macros given a bare null, and giving an anonymous struct (c_macro_null_anon.volt) */
#define FIRST(p) ((p) ? *(const int *)(p) : -1)
#define IS_NULL(p) ((p) == 0)
#define PAIR(a, b) ((struct { int x; int y; }){ (a), (b) })
#define SPAN(k) ((struct { double lo, hi; int n; }){ 0.5, 0.5 * (k), (k) })
