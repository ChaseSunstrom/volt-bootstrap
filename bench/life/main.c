// life: Conway's game of life on an n x n grid that wraps at the edges (a torus), a byte per cell,
// from a random start for 400 generations; prints the population every 100 generations and a
// checksum of the last grid
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

static size_t population(const unsigned char *cells, size_t n) {
    size_t count = 0;
    for (size_t i = 0; i < n * n; i++) count += cells[i];
    return count;
}

static void step(const unsigned char *cur, unsigned char *out, size_t n) {
    for (size_t y = 0; y < n; y++) {
        const unsigned char *up = cur + (y == 0 ? n - 1 : y - 1) * n, *row = cur + y * n, *down = cur + (y == n - 1 ? 0 : y + 1) * n;
        for (size_t x = 0; x < n; x++) {
            size_t l = x == 0 ? n - 1 : x - 1, r = x == n - 1 ? 0 : x + 1;
            int around = up[l] + up[x] + up[r] + row[l] + row[r] + down[l] + down[x] + down[r];
            out[y * n + x] = around == 3 || (around == 2 && row[x]);
        }
    }
}

int main(int argc, char **argv) {
    size_t n = argc > 1 ? (size_t)atol(argv[1]) : 1024;
    unsigned char *a = malloc(n * n), *b = malloc(n * n);
    for (size_t i = 0; i < n * n; i++) a[i] = next() % 3 == 0;
    for (int gen = 0; gen <= 400; gen++) {
        if (gen % 100 == 0) printf("generation %d: %zu alive\n", gen, population(a, n));
        if (gen == 400) break;
        step(a, b, n);
        unsigned char *t = a;
        a = b;
        b = t;
    }
    uint64_t check = 14695981039346656037ULL;
    for (size_t i = 0; i < n * n; i++) check = (check ^ a[i]) * 1099511628211ULL;
    printf("checksum %llu\n", (unsigned long long)check);
    free(a);
    free(b);
    return 0;
}
