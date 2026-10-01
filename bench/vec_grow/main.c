// vec_grow: growing arrays one push at a time (no reserve), then summing them, many times over
#include <stdio.h>
#include <stdlib.h>

int main(int argc, char **argv) {
    long n = argc > 1 ? atol(argv[1]) : 20000000;
    unsigned long total = 0;
    for (int round = 0; round < 10; round++) {
        long len = 0, cap = 0;
        long *xs = NULL;
        for (long i = 0; i < n; i++) {
            if (len == cap) {
                cap = cap ? cap * 2 : 4;
                xs = realloc(xs, sizeof(long) * cap);
            }
            xs[len++] = i * 3 + round;
        }
        for (long i = 0; i < len; i++) total += (unsigned long)xs[i];
        free(xs);
    }
    printf("%lu\n", total);
    return 0;
}
