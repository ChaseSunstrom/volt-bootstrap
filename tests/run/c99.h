/* C99: <stdbool.h>, <stdint.h>, restrict, a declaration in a for */
#include <stdbool.h>
#include <stdint.h>
static inline int32_t dot3(const int32_t *restrict a, const int32_t *restrict b) {
    int32_t s = 0;
    for (int i = 0; i < 3; i++) s += a[i] * b[i];
    return s;
}
static inline bool c99_flag(void) { return true; }
/* bit-fields Volt can't read: the struct crosses by value, Volt's copy of it with padding there */
struct c99_bits { unsigned lo : 4; unsigned hi : 4; int32_t n; };
static inline struct c99_bits c99_make_bits(int32_t n) { struct c99_bits b = {1, 2, n}; return b; }
static inline int32_t c99_bits_sum(struct c99_bits b) { return b.n + (int32_t)b.lo + (int32_t)b.hi; }
