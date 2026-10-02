// print: half a million doubles in [1, 2) as the shortest text that reads back as the same value,
// then half a million integers, a line each. libc has no shortest-float printing: the fewest
// %.*g digits that strtod reads back is the way
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>

static uint64_t x = 88172645463325252ULL;

static uint64_t next(void) {
    x ^= x << 13;
    x ^= x >> 7;
    x ^= x << 17;
    return x;
}

int main(int argc, char **argv) {
    long n = argc > 1 ? atol(argv[1]) : 500000;
    char buf[32];
    for (long i = 0; i < n; i++) {
        double v = 1.0 + (double)(next() >> 12) / 4503599627370496.0;
        for (int p = 1; p <= 17; p++) {
            snprintf(buf, sizeof buf, "%.*g", p, v);
            if (strtod(buf, 0) == v) break;
        }
        printf("%s\n", buf);
    }
    for (long i = 0; i < n; i++) printf("%lld\n", (long long)(next() >> 1));
    return 0;
}
