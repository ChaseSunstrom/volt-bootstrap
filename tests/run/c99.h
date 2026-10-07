/* C99: <stdbool.h>, <stdint.h>, restrict, a declaration in a for */
#include <stdbool.h>
#include <stdint.h>
static inline int32_t dot3(const int32_t *restrict a, const int32_t *restrict b) {
    int32_t s = 0;
    for (int i = 0; i < 3; i++) s += a[i] * b[i];
    return s;
}
static inline bool c99_flag(void) { return true; }
