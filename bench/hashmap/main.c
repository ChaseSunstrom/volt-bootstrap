// hash map churn: insert n pseudo-random keys, look each up plus as many misses, remove half
// (open addressing with linear probing, written out by hand as C programs do)
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>

typedef struct { uint64_t *keys, *vals; uint8_t *state; size_t len, used, cap; } map;

static uint64_t mix(uint64_t x) {
    uint64_t z = x + 11400714819323198485ull;
    z = (z ^ (z >> 30)) * 13787848793156543929ull;
    z = (z ^ (z >> 27)) * 10723151780598845931ull;
    return z ^ (z >> 31);
}
static size_t slot(map *m, uint64_t k) {
    size_t i = mix(k) % m->cap, free = m->cap;
    for (;;) {
        if (m->state[i] == 0) return free < m->cap ? free : i;
        if (m->state[i] == 2) { if (free == m->cap) free = i; }
        else if (m->keys[i] == k) return i;
        i = (i + 1) % m->cap;
    }
}
static void put(map *m, uint64_t k, uint64_t v);
static void grow(map *m) {
    map old = *m;
    m->cap = old.cap ? old.cap * 2 : 8;
    m->keys = malloc(m->cap * 8); m->vals = malloc(m->cap * 8); m->state = calloc(m->cap, 1);
    m->len = m->used = 0;
    for (size_t i = 0; i < old.cap; i++) if (old.state[i] == 1) put(m, old.keys[i], old.vals[i]);
    free(old.keys); free(old.vals); free(old.state);
}
static void put(map *m, uint64_t k, uint64_t v) {
    if ((m->used + 1) * 4 > m->cap * 3) grow(m);
    size_t i = slot(m, k);
    if (m->state[i] == 1) { m->vals[i] = v; return; }
    if (m->state[i] == 0) m->used++;
    m->state[i] = 1; m->len++; m->keys[i] = k; m->vals[i] = v;
}
static uint64_t *get(map *m, uint64_t k) {
    if (!m->cap) return NULL;
    size_t i = slot(m, k);
    return m->state[i] == 1 ? &m->vals[i] : NULL;
}
static int del(map *m, uint64_t k) {
    if (!m->cap) return 0;
    size_t i = slot(m, k);
    if (m->state[i] != 1) return 0;
    m->state[i] = 2; m->len--;
    return 1;
}

int main(int argc, char **argv) {
    long n = argc > 1 ? atol(argv[1]) : 5000000;
    map m = {0};
    uint64_t x = 42, sum = 0, found = 0;
    for (long i = 0; i < n; i++) { x = x * 6364136223846793005ull + 1442695040888963407ull; put(&m, x >> 16, (uint64_t)i); }
    x = 42;
    for (long i = 0; i < n; i++) {
        x = x * 6364136223846793005ull + 1442695040888963407ull;
        uint64_t *v = get(&m, x >> 16); if (v) { sum += *v; found++; }
        if (get(&m, (x >> 16) + 1)) found++;
    }
    x = 42;
    long removed = 0;
    for (long i = 0; i < n; i += 2) {
        x = x * 6364136223846793005ull + 1442695040888963407ull;
        removed += del(&m, x >> 16);
        x = x * 6364136223846793005ull + 1442695040888963407ull;
    }
    printf("%zu %llu %llu %ld\n", m.len, (unsigned long long)found, (unsigned long long)sum, removed);
    free(m.keys); free(m.vals); free(m.state);
    return 0;
}
