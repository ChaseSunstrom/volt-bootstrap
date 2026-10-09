// btree: an ordered map from u64 to u64 under random inserts (some overwriting), lookups (two in five
// of them hits) and range scans of 100 entries from a random key; prints the size, the hits and a
// checksum of what the lookups and scans saw. C writes a B-tree for u64 keys (31 keys a node,
// splitting full nodes on the way down), its nodes malloc'd
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define MAX 31 // keys in a node; a full one splits into two of 15 around its middle key

typedef struct node {
    int n, leaf;
    uint64_t keys[MAX], vals[MAX];
    struct node *kids[MAX + 1];
} node;

typedef struct { node *root; size_t len; } btree;

static node *node_new(int leaf) {
    node *x = malloc(sizeof(node));
    x->n = 0;
    x->leaf = leaf;
    return x;
}

static void node_free(node *x) {
    if (!x->leaf)
        for (int i = 0; i <= x->n; i++) node_free(x->kids[i]);
    free(x);
}

// the first key in x not below k
static int lower(const node *x, uint64_t k) {
    int i = 0;
    while (i < x->n && x->keys[i] < k) i++;
    return i;
}

// x->kids[i] is full: its upper half moves to a new node after it, and its middle key up into x
static void split_child(node *x, int i) {
    node *y = x->kids[i], *z = node_new(y->leaf);
    int half = MAX / 2;
    z->n = half;
    memcpy(z->keys, y->keys + half + 1, half * sizeof(uint64_t));
    memcpy(z->vals, y->vals + half + 1, half * sizeof(uint64_t));
    if (!y->leaf) memcpy(z->kids, y->kids + half + 1, (half + 1) * sizeof(node *));
    y->n = half;
    memmove(x->kids + i + 2, x->kids + i + 1, (x->n - i) * sizeof(node *));
    x->kids[i + 1] = z;
    memmove(x->keys + i + 1, x->keys + i, (x->n - i) * sizeof(uint64_t));
    memmove(x->vals + i + 1, x->vals + i, (x->n - i) * sizeof(uint64_t));
    x->keys[i] = y->keys[half];
    x->vals[i] = y->vals[half];
    x->n++;
}

static void btree_put(btree *t, uint64_t k, uint64_t v) {
    if (t->root->n == MAX) {
        node *r = node_new(0);
        r->kids[0] = t->root;
        t->root = r;
        split_child(r, 0);
    }
    node *x = t->root;
    for (;;) {
        int i = lower(x, k);
        if (i < x->n && x->keys[i] == k) {
            x->vals[i] = v;
            return;
        }
        if (x->leaf) {
            memmove(x->keys + i + 1, x->keys + i, (x->n - i) * sizeof(uint64_t));
            memmove(x->vals + i + 1, x->vals + i, (x->n - i) * sizeof(uint64_t));
            x->keys[i] = k;
            x->vals[i] = v;
            x->n++;
            t->len++;
            return;
        }
        if (x->kids[i]->n == MAX) {
            split_child(x, i);
            if (k == x->keys[i]) {
                x->vals[i] = v;
                return;
            }
            if (k > x->keys[i]) i++;
        }
        x = x->kids[i];
    }
}

static uint64_t *btree_get(const btree *t, uint64_t k) {
    node *x = t->root;
    for (;;) {
        int i = lower(x, k);
        if (i < x->n && x->keys[i] == k) return &x->vals[i];
        if (x->leaf) return NULL;
        x = x->kids[i];
    }
}

// calls visit on the entries from the first key not below lo, in order, while *left > 0
static void scan(const node *x, uint64_t lo, size_t *left, void (*visit)(uint64_t, uint64_t, void *), void *ctx) {
    for (int i = lower(x, lo); i <= x->n; i++) {
        if (!x->leaf) {
            scan(x->kids[i], lo, left, visit, ctx);
            if (*left == 0) return;
        }
        if (i == x->n) return;
        visit(x->keys[i], x->vals[i], ctx);
        if (--*left == 0) return;
    }
}

static void add_entry(uint64_t k, uint64_t v, void *ctx) {
    uint64_t *check = ctx;
    *check = *check * 31 + k + v;
}

static uint64_t x = 88172645463325252ULL;

static uint64_t next(void) {
    x ^= x << 13;
    x ^= x >> 7;
    x ^= x << 17;
    return x;
}

int main(int argc, char **argv) {
    size_t n = argc > 1 ? (size_t)atol(argv[1]) : 2000000;
    uint64_t space = 2 * n; // keys are drawn from 0..space
    btree t = { node_new(1), 0 };
    for (size_t i = 0; i < n; i++) btree_put(&t, next() % space, i);
    size_t hits = 0;
    uint64_t check = 0;
    for (size_t i = 0; i < n; i++) {
        uint64_t *v = btree_get(&t, next() % space);
        if (v) {
            hits++;
            check += *v;
        }
    }
    for (size_t i = 0; i < n / 10; i++) {
        size_t left = 100;
        scan(t.root, next() % space, &left, add_entry, &check);
    }
    printf("%zu entries, %zu of %zu lookups found\n", t.len, hits, n);
    printf("checksum %llu\n", (unsigned long long)check);
    node_free(t.root);
    return 0;
}
