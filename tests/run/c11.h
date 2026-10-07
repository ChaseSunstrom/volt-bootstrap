/* C11: _Static_assert, _Alignas, anonymous members */
_Static_assert(sizeof(int) == 4, "int is 32 bits");
typedef struct {
    _Alignas(16) int v;
    struct { int lo, hi; };
} aligned16;
static inline int c11_span(aligned16 a) { return a.hi - a.lo + a.v; }
