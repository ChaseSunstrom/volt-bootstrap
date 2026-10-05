// wordfreq: count the words of a text of n words drawn from a Zipf-like vocabulary in a hash map keyed
// by string, then print the 20 most frequent; C uses a hand-written open-addressing table (FNV-1a,
// linear probing) whose keys point into the text, and qsort
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static uint64_t x = 88172645463325252ULL;

static uint64_t next(void) {
    x ^= x << 13;
    x ^= x >> 7;
    x ^= x << 17;
    return x;
}

typedef struct { const char *word; size_t len; long count; } entry;
typedef struct { entry *slots; size_t cap, len; } table;

static uint64_t fnv1a(const char *s, size_t n) {
    uint64_t h = 14695981039346656037ULL;
    for (size_t i = 0; i < n; i++) h = (h ^ (unsigned char)s[i]) * 1099511628211ULL;
    return h;
}

static entry *slot(entry *slots, size_t cap, const char *w, size_t n) {
    size_t i = fnv1a(w, n) & (cap - 1);
    while (slots[i].word && !(slots[i].len == n && memcmp(slots[i].word, w, n) == 0)) i = (i + 1) & (cap - 1);
    return &slots[i];
}

static void grow(table *t) {
    size_t cap = t->cap ? t->cap * 2 : 1024;
    entry *slots = calloc(cap, sizeof *slots);
    for (size_t i = 0; i < t->cap; i++)
        if (t->slots[i].word) *slot(slots, cap, t->slots[i].word, t->slots[i].len) = t->slots[i];
    free(t->slots);
    t->slots = slots;
    t->cap = cap;
}

// the word's entry, added with count 0 when it's new
static entry *find_or_add(table *t, const char *w, size_t n) {
    if ((t->len + 1) * 4 > t->cap * 3) grow(t);
    entry *e = slot(t->slots, t->cap, w, n);
    if (!e->word) { *e = (entry){w, n, 0}; t->len++; }
    return e;
}

// most frequent first, ties alphabetically
static int by_count(const void *a, const void *b) {
    const entry *p = a, *q = b;
    if (p->count != q->count) return p->count > q->count ? -1 : 1;
    size_t n = p->len < q->len ? p->len : q->len;
    int c = memcmp(p->word, q->word, n);
    if (c) return c;
    return (p->len > q->len) - (p->len < q->len);
}

#define VOCAB (1 << 18)

int main(int argc, char **argv) {
    long n = argc > 1 ? atol(argv[1]) : 20000000;
    // the vocabulary: random lowercase words of 3 to 10 letters
    char (*words)[10] = malloc(VOCAB * sizeof *words);
    size_t *lens = malloc(VOCAB * sizeof *lens);
    for (int k = 0; k < VOCAB; k++) {
        lens[k] = 3 + next() % 8;
        for (size_t j = 0; j < lens[k]; j++) words[k][j] = 'a' + next() % 26;
    }
    // the text: word k is picked about 1/k as often as word 1
    size_t len = 0, cap = 1 << 20;
    char *text = malloc(cap);
    for (long i = 0; i < n; i++) {
        uint64_t bits = next() % 19;
        uint64_t k = next() & ((1ULL << bits) - 1);
        if (len + 11 > cap) { cap *= 2; text = realloc(text, cap); }
        memcpy(text + len, words[k], lens[k]);
        len += lens[k];
        text[len++] = ' ';
    }
    table t = {0};
    size_t start = 0;
    long total = 0;
    for (size_t i = 0; i < len; i++) {
        if (text[i] == ' ') {
            find_or_add(&t, text + start, i - start)->count++;
            total++;
            start = i + 1;
        }
    }
    entry *all = malloc(t.len * sizeof *all);
    size_t m = 0;
    for (size_t i = 0; i < t.cap; i++) if (t.slots[i].word) all[m++] = t.slots[i];
    qsort(all, m, sizeof *all, by_count);
    printf("%zu bytes, %ld words, %zu distinct\n", len, total, m);
    for (size_t i = 0; i < 20 && i < m; i++) printf("%.*s %ld\n", (int)all[i].len, all[i].word, all[i].count);
    free(all);
    free(t.slots);
    free(text);
    free(lens);
    free(words);
    return 0;
}
