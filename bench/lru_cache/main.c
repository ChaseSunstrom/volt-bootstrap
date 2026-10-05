// lru_cache: an LRU cache of 100000 int keys to owned strings under n skewed get/put operations
// (a miss puts the value); C uses malloc'd nodes on a doubly linked list with a sentinel, found
// through a hand-written chained hash table, and malloc'd value bytes
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

typedef struct node {
    uint64_t key;
    char *val;
    size_t len;
    struct node *prev, *next; // recency: head.next is the most recent
    struct node *chain;       // the next node in the same bucket
} node;

typedef struct {
    node head; // sentinel of the circular recency list
    node **buckets;
    size_t mask, size, cap;
} lru;

static void lru_init(lru *c, size_t cap) {
    size_t nb = 1;
    while (nb < cap * 2) nb *= 2;
    c->buckets = calloc(nb, sizeof *c->buckets);
    c->mask = nb - 1;
    c->size = 0;
    c->cap = cap;
    c->head.prev = c->head.next = &c->head;
}

static size_t bucket(const lru *c, uint64_t key) {
    // splitmix64's finalizer spreads the bits
    uint64_t z = key + 0x9E3779B97F4A7C15ULL;
    z = (z ^ (z >> 30)) * 0xBF58476D1CE4E5B9ULL;
    z = (z ^ (z >> 27)) * 0x94D049BB133111EBULL;
    return (z ^ (z >> 31)) & c->mask;
}

static void unlink_node(node *n) { n->prev->next = n->next; n->next->prev = n->prev; }

static void push_front(lru *c, node *n) {
    n->prev = &c->head;
    n->next = c->head.next;
    c->head.next->prev = n;
    c->head.next = n;
}

static node *find(lru *c, uint64_t key) {
    node *n = c->buckets[bucket(c, key)];
    while (n && n->key != key) n = n->chain;
    return n;
}

// the value for key (marked most recent), or NULL
static const node *lru_get(lru *c, uint64_t key) {
    node *n = find(c, key);
    if (!n) return NULL;
    unlink_node(n);
    push_front(c, n);
    return n;
}

// set key to the len bytes at val (taking them), evicting the least recent key when full
static void lru_put(lru *c, uint64_t key, char *val, size_t len) {
    node *n = find(c, key);
    if (n) {
        free(n->val);
        n->val = val;
        n->len = len;
        unlink_node(n);
        push_front(c, n);
        return;
    }
    if (c->size == c->cap) {
        node *old = c->head.prev;
        unlink_node(old);
        node **p = &c->buckets[bucket(c, old->key)];
        while (*p != old) p = &(*p)->chain;
        *p = old->chain;
        free(old->val);
        free(old);
        c->size--;
    }
    n = malloc(sizeof *n);
    n->key = key;
    n->val = val;
    n->len = len;
    size_t b = bucket(c, key);
    n->chain = c->buckets[b];
    c->buckets[b] = n;
    push_front(c, n);
    c->size++;
}

static void lru_free(lru *c) {
    node *n = c->head.next;
    while (n != &c->head) { node *after = n->next; free(n->val); free(n); n = after; }
    free(c->buckets);
}

static const char PATTERN[] = "abcdefghijklmnopqrstuvwxyzabcdefghijklmnopqrstuvwxyzabcdefghijklmnop";

// the value stored for key at step i: 8 to 32 letters
static char *make_value(uint64_t key, long i, size_t *len) {
    *len = 8 + (key + i) % 25;
    char *v = malloc(*len);
    memcpy(v, PATTERN + key % 26, *len);
    return v;
}

int main(int argc, char **argv) {
    long n = argc > 1 ? atol(argv[1]) : 20000000;
    lru c;
    lru_init(&c, 100000);
    long hits = 0, misses = 0, total = 0;
    for (long i = 0; i < n; i++) {
        uint64_t r = next();
        // three in four keys come from a hot set a little bigger than the cache
        uint64_t key = r % 4 ? next() % 120000 : next() % 1000000;
        size_t len;
        if ((r >> 8) % 10 == 0) {
            char *v = make_value(key, i, &len);
            lru_put(&c, key, v, len);
            continue;
        }
        const node *hit = lru_get(&c, key);
        if (hit) {
            hits++;
            total += hit->len;
        } else {
            misses++;
            char *v = make_value(key, i, &len);
            lru_put(&c, key, v, len);
        }
    }
    printf("%ld hits, %ld misses, %ld total, %zu cached\n", hits, misses, total, c.size);
    lru_free(&c);
    return 0;
}
