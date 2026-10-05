// heap: a binary min-heap used for two element types: n random integers, then n tasks ordered by
// (priority, id), each pushed then popped in order; C writes the heap once over void * with an
// element size and a comparison function, as qsort does
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static uint64_t seed = 88172645463325252ULL;
static uint64_t next(void) {
    seed ^= seed << 13;
    seed ^= seed >> 7;
    seed ^= seed << 17;
    return seed;
}

typedef struct {
    char *data;
    size_t len, cap, size;
    int (*less)(const void *, const void *);
} heap;

static void *at(heap *h, size_t i) { return h->data + i * h->size; }

static void swap(heap *h, size_t i, size_t j) {
    char tmp[64];
    memcpy(tmp, at(h, i), h->size);
    memcpy(at(h, i), at(h, j), h->size);
    memcpy(at(h, j), tmp, h->size);
}

static void push(heap *h, const void *x) {
    if (h->len == h->cap) {
        h->cap = h->cap ? h->cap * 2 : 16;
        h->data = realloc(h->data, h->cap * h->size);
    }
    memcpy(at(h, h->len), x, h->size);
    size_t i = h->len++;
    while (i > 0) {
        size_t p = (i - 1) / 2;
        if (!h->less(at(h, i), at(h, p))) break;
        swap(h, i, p);
        i = p;
    }
}

static void pop(heap *h, void *out) {
    memcpy(out, at(h, 0), h->size);
    h->len--;
    memcpy(at(h, 0), at(h, h->len), h->size);
    size_t i = 0;
    for (;;) {
        size_t l = 2 * i + 1, r = l + 1, m = i;
        if (l < h->len && h->less(at(h, l), at(h, m))) m = l;
        if (r < h->len && h->less(at(h, r), at(h, m))) m = r;
        if (m == i) break;
        swap(h, i, m);
        i = m;
    }
}

typedef struct {
    uint32_t priority, id;
} task;

static int less_u64(const void *a, const void *b) { return *(const uint64_t *)a < *(const uint64_t *)b; }
static int less_task(const void *a, const void *b) {
    const task *x = a, *y = b;
    return x->priority < y->priority || (x->priority == y->priority && x->id < y->id);
}

int main(int argc, char **argv) {
    size_t n = argc > 1 ? strtoul(argv[1], 0, 10) : 3000000;
    heap ints = {0, 0, 0, sizeof(uint64_t), less_u64};
    for (size_t i = 0; i < n; i++) {
        uint64_t v = next() >> 16;
        push(&ints, &v);
    }
    uint64_t sum = 0, prev = 0, sorted = 1;
    for (size_t i = 0; i < n; i++) {
        uint64_t v;
        pop(&ints, &v);
        sorted &= prev <= v;
        prev = v;
        sum = sum * 31 + v;
    }
    heap tasks = {0, 0, 0, sizeof(task), less_task};
    for (size_t i = 0; i < n; i++) {
        task t = {(uint32_t)(next() % 1000), (uint32_t)i};
        push(&tasks, &t);
    }
    uint64_t order = 0;
    for (size_t i = 0; i < n; i++) {
        task t;
        pop(&tasks, &t);
        order = order * 31 + t.id;
    }
    printf("%llu %llu %llu\n", (unsigned long long)sorted, (unsigned long long)sum, (unsigned long long)order);
    free(ints.data);
    free(tasks.data);
    return 0;
}
