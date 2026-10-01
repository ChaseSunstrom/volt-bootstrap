// closures: a map / filter / fold pipeline over an array, many rounds; C passes a function pointer
// and a context pointer, as C libraries do
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>

typedef int64_t (*map_fn)(void *ctx, int64_t x);
typedef int (*keep_fn)(void *ctx, int64_t x);

static int64_t pipeline(const int64_t *xs, long n, map_fn f, void *fc, keep_fn k, void *kc) {
    int64_t sum = 0;
    for (long i = 0; i < n; i++) { int64_t y = f(fc, xs[i]); if (k(kc, y)) sum += y; }
    return sum;
}
static int64_t scale(void *ctx, int64_t x) { return x * *(int64_t *)ctx + 1; }
static int below(void *ctx, int64_t x) { return x % 3 != 0 && x < *(int64_t *)ctx; }

int main(int argc, char **argv) {
    long rounds = argc > 1 ? atol(argv[1]) : 1000;
    long n = 1000000;
    int64_t *xs = malloc(n * sizeof *xs);
    for (long i = 0; i < n; i++) xs[i] = i % 1000;
    int64_t total = 0;
    for (long r = 0; r < rounds; r++) {
        int64_t factor = r % 7 + 2, limit = 5000 - r;
        total += pipeline(xs, n, scale, &factor, below, &limit);
    }
    printf("%lld\n", (long long)total);
    free(xs);
    return 0;
}
