// dijkstra: shortest paths over an n x n grid whose edges have random weights, from two corners,
// with a binary heap of (distance, node) and lazy deletion; C keeps the weights in one array and
// writes the heap by hand
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>

static uint64_t seed = 88172645463325252ULL;
static uint64_t next(void) {
    seed ^= seed << 13;
    seed ^= seed >> 7;
    seed ^= seed << 17;
    return seed;
}

typedef struct {
    uint64_t dist;
    uint32_t node;
} item;

typedef struct {
    item *items;
    size_t len, cap;
} heap;

static int before(item a, item b) { return a.dist < b.dist || (a.dist == b.dist && a.node < b.node); }

static void push(heap *h, item x) {
    if (h->len == h->cap) {
        h->cap = h->cap ? h->cap * 2 : 1024;
        h->items = realloc(h->items, h->cap * sizeof(item));
    }
    size_t i = h->len++;
    h->items[i] = x;
    while (i > 0) {
        size_t p = (i - 1) / 2;
        if (!before(h->items[i], h->items[p])) break;
        item t = h->items[i];
        h->items[i] = h->items[p];
        h->items[p] = t;
        i = p;
    }
}

static item pop(heap *h) {
    item top = h->items[0];
    h->items[0] = h->items[--h->len];
    size_t i = 0;
    for (;;) {
        size_t l = 2 * i + 1, r = l + 1, m = i;
        if (l < h->len && before(h->items[l], h->items[m])) m = l;
        if (r < h->len && before(h->items[r], h->items[m])) m = r;
        if (m == i) break;
        item t = h->items[i];
        h->items[i] = h->items[m];
        h->items[m] = t;
        i = m;
    }
    return top;
}

// distances from src to every node; weight[node * 4 + d] is the cost of leaving node in direction d
static void shortest(size_t n, const uint32_t *weight, uint32_t src, uint64_t *dist, uint64_t *relaxed) {
    size_t count = n * n;
    for (size_t i = 0; i < count; i++) dist[i] = UINT64_MAX;
    heap h = {0, 0, 0};
    dist[src] = 0;
    push(&h, (item){0, src});
    while (h.len > 0) {
        item cur = pop(&h);
        if (cur.dist > dist[cur.node]) continue;
        size_t x = cur.node % n, y = cur.node / n;
        for (int d = 0; d < 4; d++) {
            size_t nx = x, ny = y;
            if (d == 0) { if (x + 1 >= n) continue; nx = x + 1; }
            else if (d == 1) { if (x == 0) continue; nx = x - 1; }
            else if (d == 2) { if (y + 1 >= n) continue; ny = y + 1; }
            else { if (y == 0) continue; ny = y - 1; }
            uint32_t to = (uint32_t)(ny * n + nx);
            uint64_t nd = cur.dist + weight[cur.node * 4 + d];
            if (nd < dist[to]) {
                dist[to] = nd;
                *relaxed += 1;
                push(&h, (item){nd, to});
            }
        }
    }
    free(h.items);
}

int main(int argc, char **argv) {
    size_t n = argc > 1 ? strtoul(argv[1], 0, 10) : 1500;
    size_t count = n * n;
    uint32_t *weight = malloc(count * 4 * sizeof(uint32_t));
    for (size_t i = 0; i < count * 4; i++) weight[i] = (uint32_t)(next() % 100) + 1;
    uint64_t *dist = malloc(count * sizeof(uint64_t));
    uint64_t relaxed = 0;
    uint32_t sources[2] = {0, (uint32_t)(count - 1)};
    for (int s = 0; s < 2; s++) {
        shortest(n, weight, sources[s], dist, &relaxed);
        uint64_t sum = 0, far = 0;
        for (size_t i = 0; i < count; i++) {
            sum += dist[i];
            if (dist[i] > far) far = dist[i];
        }
        printf("from %u: corner %llu, farthest %llu, sum %llu\n", sources[s], (unsigned long long)dist[sources[1 - s]], (unsigned long long)far, (unsigned long long)sum);
    }
    printf("relaxed %llu\n", (unsigned long long)relaxed);
    free(weight);
    free(dist);
    return 0;
}
