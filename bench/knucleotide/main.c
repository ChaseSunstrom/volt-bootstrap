// k-nucleotide (the Benchmarks Game): count the k-mers of a long DNA string, k = 1 and 2 as sorted
// frequencies, and five longer ones (up to 18 bases) by building a table for each length; C packs
// the bases 2 bits each into a uint64_t key, in a hand-written open-addressing table
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

typedef struct { uint64_t key; uint32_t count; } slot; // count 0: empty
typedef struct { slot *slots; size_t len, cap; } table;

static uint64_t mix(uint64_t x) {
    uint64_t z = x + 11400714819323198485ull;
    z = (z ^ (z >> 30)) * 13787848793156543929ull;
    z = (z ^ (z >> 27)) * 10723151780598845931ull;
    return z ^ (z >> 31);
}

static void table_init(table *t) {
    t->cap = 16;
    t->len = 0;
    t->slots = calloc(t->cap, sizeof(slot));
}

static slot *table_find(table *t, uint64_t key) {
    size_t i = mix(key) & (t->cap - 1);
    while (t->slots[i].count != 0 && t->slots[i].key != key) i = (i + 1) & (t->cap - 1);
    return &t->slots[i];
}

static void table_add(table *t, uint64_t key) {
    slot *s = table_find(t, key);
    if (s->count != 0) {
        s->count++;
        return;
    }
    if ((t->len + 1) * 4 > t->cap * 3) {
        slot *old = t->slots;
        size_t old_cap = t->cap;
        t->cap *= 2;
        t->slots = calloc(t->cap, sizeof(slot));
        for (size_t i = 0; i < old_cap; i++)
            if (old[i].count != 0) *table_find(t, old[i].key) = old[i];
        free(old);
        s = table_find(t, key);
    }
    s->key = key;
    s->count = 1;
    t->len++;
}

// every k-mer of codes[0..n), its bases 2 bits each
static void count(table *t, const uint8_t *codes, size_t n, size_t k) {
    uint64_t mask = (1ull << (2 * k)) - 1, key = 0;
    table_init(t);
    for (size_t i = 0; i < n; i++) {
        key = ((key << 2) | codes[i]) & mask;
        if (i + 1 >= k) table_add(t, key);
    }
}

static const char LETTERS[] = "ACGT";

static int by_count(const void *a, const void *b) {
    const slot *x = a, *y = b;
    if (x->count != y->count) return x->count > y->count ? -1 : 1;
    return x->key < y->key ? -1 : x->key > y->key; // same length, so key order is letter order
}

static void frequencies(const uint8_t *codes, size_t n, size_t k) {
    table t;
    count(&t, codes, n, k);
    slot *all = malloc(t.len * sizeof(slot));
    size_t m = 0;
    for (size_t i = 0; i < t.cap; i++)
        if (t.slots[i].count != 0) all[m++] = t.slots[i];
    qsort(all, m, sizeof(slot), by_count);
    char name[33];
    for (size_t i = 0; i < m; i++) {
        for (size_t j = 0; j < k; j++) name[j] = LETTERS[(all[i].key >> (2 * (k - 1 - j))) & 3];
        name[k] = 0;
        printf("%s %.3f\n", name, 100.0 * all[i].count / (n - k + 1));
    }
    printf("\n");
    free(all);
    free(t.slots);
}

static uint8_t code_of(char c) {
    switch (c) {
    case 'A': return 0;
    case 'C': return 1;
    case 'G': return 2;
    default: return 3;
    }
}

static void occurrences(const uint8_t *codes, size_t n, const char *seq) {
    size_t k = strlen(seq);
    uint64_t key = 0;
    for (size_t j = 0; j < k; j++) key = (key << 2) | code_of(seq[j]);
    table t;
    count(&t, codes, n, k);
    slot *s = table_find(&t, key);
    printf("%u\t%s\n", s->count, seq);
    free(t.slots);
}

static uint64_t x = 88172645463325252ULL;

static uint64_t next(void) {
    x ^= x << 13;
    x ^= x >> 7;
    x ^= x << 17;
    return x;
}

int main(int argc, char **argv) {
    size_t n = argc > 1 ? (size_t)atol(argv[1]) : 25000000;
    // the bases at the human genome's frequencies; the generator that made the original input
    // (fasta) repeats every 139968 numbers, so this sequence repeats with that period too
    const size_t period = 139968;
    char *dna = malloc(n);
    for (size_t i = 0; i < n; i++) {
        if (i >= period) {
            dna[i] = dna[i - period];
            continue;
        }
        uint64_t r = (next() >> 32) % 1000;
        dna[i] = r < 303 ? 'A' : r < 501 ? 'C' : r < 699 ? 'G' : 'T';
    }
    uint8_t *codes = malloc(n);
    for (size_t i = 0; i < n; i++) codes[i] = code_of(dna[i]);
    frequencies(codes, n, 1);
    frequencies(codes, n, 2);
    static const char *const seqs[] = { "GGT", "GGTA", "GGTATT", "GGTATTTTAATT", "GGTATTTTAATTTATAGT" };
    for (int i = 0; i < 5; i++) occurrences(codes, n, seqs[i]);
    free(dna);
    free(codes);
    return 0;
}
