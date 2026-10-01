// sort: n pseudo-random 64-bit integers with the C library's qsort
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>

static int cmp(const void *a, const void *b) {
    int64_t x = *(const int64_t *)a, y = *(const int64_t *)b;
    return (x > y) - (x < y);
}

int main(int argc, char **argv) {
    long n = argc > 1 ? atol(argv[1]) : 5000000;
    int64_t *xs = malloc(n * sizeof *xs);
    uint64_t s = 7;
    for (long i = 0; i < n; i++) { s = s * 6364136223846793005ull + 1442695040888963407ull; xs[i] = (int64_t)(s >> 1) % 1000000007; }
    qsort(xs, n, sizeof *xs, cmp);
    uint64_t check = 0;
    for (long i = 0; i < n; i++) check = check * 31 + (uint64_t)xs[i];
    printf("%lld %lld %llu\n", (long long)xs[0], (long long)xs[n - 1], (unsigned long long)check);
    free(xs);
    return 0;
}
