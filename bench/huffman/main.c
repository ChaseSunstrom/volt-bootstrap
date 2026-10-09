// huffman: Huffman-code a skewed 64-letter text: count the letters, build the code tree from a
// priority queue of (weight, node), write every letter's code as bits, then read the bits back a bit
// at a time down the tree and check the round trip; C uses a hand-written binary heap and -1 for "no
// child"
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

typedef struct { uint64_t weight; int left, right; unsigned char sym; } node; // a leaf has left -1
typedef struct { uint64_t weight; int id; } item;

// a min-heap of items, lightest first, then lowest id
typedef struct { item *a; size_t len; } heap;

static int less(item x, item y) { return x.weight < y.weight || (x.weight == y.weight && x.id < y.id); }

static void heap_push(heap *h, item v) {
    size_t i = h->len++;
    while (i > 0 && less(v, h->a[(i - 1) / 2])) {
        h->a[i] = h->a[(i - 1) / 2];
        i = (i - 1) / 2;
    }
    h->a[i] = v;
}

static item heap_pop(heap *h) {
    item top = h->a[0], last = h->a[--h->len];
    size_t i = 0;
    for (;;) {
        size_t c = 2 * i + 1;
        if (c >= h->len) break;
        if (c + 1 < h->len && less(h->a[c + 1], h->a[c])) c++;
        if (!less(h->a[c], last)) break;
        h->a[i] = h->a[c];
        i = c;
    }
    h->a[i] = last;
    return top;
}

static void assign(const node *nodes, int id, uint64_t code, int len, uint64_t *codes, int *lens) {
    if (nodes[id].left < 0) {
        codes[nodes[id].sym] = code;
        lens[nodes[id].sym] = len;
        return;
    }
    assign(nodes, nodes[id].left, code << 1, len + 1, codes, lens);
    assign(nodes, nodes[id].right, (code << 1) | 1, len + 1, codes, lens);
}

static uint64_t fnv(const unsigned char *s, size_t n) {
    uint64_t h = 14695981039346656037ULL;
    for (size_t i = 0; i < n; i++) h = (h ^ s[i]) * 1099511628211ULL;
    return h;
}

static uint64_t x = 88172645463325252ULL;

static uint64_t next(void) {
    x ^= x << 13;
    x ^= x >> 7;
    x ^= x << 17;
    return x;
}

int main(int argc, char **argv) {
    size_t n = argc > 1 ? (size_t)atol(argv[1]) : 33554432;
    // the text: letters of a 64-letter alphabet, the first ones the most common
    const char *alphabet = "etaoinshrdlcumwfgypbvkjxqzETAOINSHRDLCUMWFGYPBVKJXQZ0123456789 .";
    unsigned char *text = malloc(n);
    for (size_t i = 0; i < n; i++) {
        uint64_t r = next();
        text[i] = (unsigned char)alphabet[((r >> 8) % 64) * ((r >> 20) % 64) / 63];
    }
    uint64_t count[256] = { 0 };
    for (size_t i = 0; i < n; i++) count[text[i]]++;
    // a leaf per letter that occurs, in byte order; then a node joining the two lightest, until one is left
    node nodes[511];
    int k = 0;
    heap h = { malloc(256 * sizeof(item)), 0 };
    for (int c = 0; c < 256; c++)
        if (count[c] > 0) {
            nodes[k] = (node){ count[c], -1, -1, (unsigned char)c };
            heap_push(&h, (item){ count[c], k });
            k++;
        }
    int symbols = k;
    while (h.len > 1) {
        item a = heap_pop(&h), b = heap_pop(&h);
        nodes[k] = (node){ a.weight + b.weight, a.id, b.id, 0 };
        heap_push(&h, (item){ a.weight + b.weight, k });
        k++;
    }
    int root = heap_pop(&h).id;
    uint64_t codes[256] = { 0 };
    int lens[256] = { 0 }, longest = 0;
    assign(nodes, root, 0, 0, codes, lens);
    for (int c = 0; c < 256; c++)
        if (lens[c] > longest) longest = lens[c];
    // write the codes, the first bit of each byte the highest
    unsigned char *packed = malloc(n * longest / 8 + 1);
    size_t used = 0;
    uint64_t acc = 0;
    int bits = 0;
    for (size_t i = 0; i < n; i++) {
        acc = (acc << lens[text[i]]) | codes[text[i]];
        bits += lens[text[i]];
        while (bits >= 8) {
            bits -= 8;
            packed[used++] = (unsigned char)(acc >> bits);
        }
    }
    if (bits > 0) packed[used++] = (unsigned char)(acc << (8 - bits));
    // read them back down the tree
    unsigned char *back = malloc(n);
    size_t pos = 0;
    for (size_t i = 0; i < n; i++) {
        int id = root;
        while (nodes[id].left >= 0) {
            int bit = (packed[pos >> 3] >> (7 - (pos & 7))) & 1;
            pos++;
            id = bit ? nodes[id].right : nodes[id].left;
        }
        back[i] = nodes[id].sym;
    }
    if (memcmp(back, text, n) != 0) {
        fprintf(stderr, "round trip failed\n");
        return 1;
    }
    printf("%zu letters, %d symbols, longest code %d bits\n", n, symbols, longest);
    printf("packed %zu bytes, checksum %llu\n", used, (unsigned long long)fnv(packed, used));
    printf("unpacked %zu bytes, checksum %llu\n", n, (unsigned long long)fnv(back, n));
    free(text);
    free(packed);
    free(back);
    free(h.a);
    return 0;
}
