// lz77: compress a repetitive text with LZ77 (a hash table of recent positions, chains of at most 8
// probes, a 64 KiB window), decompress it and check the round trip; C works on malloc'd byte arrays
// with pointers, and the decoder returns -1 for corrupt input
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

// the format: a byte c < 128 is followed by c + 1 literal bytes; c >= 128 is a match of
// c - 128 + MIN_MATCH bytes, then its distance back (1..MAX_DIST) in two bytes, low first
enum { HASH_BITS = 16, WINDOW = 1 << 16, MIN_MATCH = 4, MAX_MATCH = MIN_MATCH + 127, MAX_CHAIN = 8, MAX_DIST = WINDOW - 1 };

static uint32_t hash4(const uint8_t *p) {
    uint32_t v = (uint32_t)p[0] | (uint32_t)p[1] << 8 | (uint32_t)p[2] << 16 | (uint32_t)p[3] << 24;
    return (v * 2654435761u) >> (32 - HASH_BITS);
}

static uint8_t *put_literals(uint8_t *out, const uint8_t *from, const uint8_t *to) {
    while (from < to) {
        size_t k = to - from > 128 ? 128 : (size_t)(to - from);
        *out++ = (uint8_t)(k - 1);
        memcpy(out, from, k);
        out += k;
        from += k;
    }
    return out;
}

// compresses in[0..n) into out, which has room for n + n / 128 + 16 bytes; returns the size
static size_t compress(const uint8_t *in, size_t n, uint8_t *out) {
    int32_t *head = malloc(sizeof(int32_t) << HASH_BITS), *prev = malloc(sizeof(int32_t) * WINDOW);
    for (size_t h = 0; h < 1u << HASH_BITS; h++) head[h] = -1;
    uint8_t *o = out;
    size_t i = 0, lit = 0;
    while (i + MIN_MATCH <= n) {
        uint32_t h = hash4(in + i);
        size_t best = 0, dist = 0, limit = n - i < MAX_MATCH ? n - i : MAX_MATCH;
        int32_t cand = head[h];
        for (int probes = 0; cand >= 0 && i - (size_t)cand <= MAX_DIST && probes < MAX_CHAIN; probes++) {
            const uint8_t *a = in + cand, *b = in + i;
            size_t len = 0;
            while (len < limit && a[len] == b[len]) len++;
            if (len > best) {
                best = len;
                dist = i - (size_t)cand;
                if (len == limit) break;
            }
            cand = prev[cand & (WINDOW - 1)];
        }
        prev[i & (WINDOW - 1)] = head[h];
        head[h] = (int32_t)i;
        if (best >= MIN_MATCH) {
            o = put_literals(o, in + lit, in + i);
            *o++ = (uint8_t)(128 + best - MIN_MATCH);
            *o++ = (uint8_t)dist;
            *o++ = (uint8_t)(dist >> 8);
            // the positions inside the match go into the table too
            for (size_t j = i + 1; j < i + best && j + MIN_MATCH <= n; j++) {
                uint32_t hj = hash4(in + j);
                prev[j & (WINDOW - 1)] = head[hj];
                head[hj] = (int32_t)j;
            }
            i += best;
            lit = i;
        } else {
            i++;
        }
    }
    o = put_literals(o, in + lit, in + n);
    free(head);
    free(prev);
    return (size_t)(o - out);
}

// decompresses src[0..n) into dst, which has room for cap bytes; returns the size, or -1 when
// the input is corrupt
static long decompress(const uint8_t *src, size_t n, uint8_t *dst, size_t cap) {
    const uint8_t *p = src, *end = src + n;
    uint8_t *o = dst, *oend = dst + cap;
    while (p < end) {
        unsigned c = *p++;
        if (c < 128) {
            size_t k = c + 1;
            if ((size_t)(end - p) < k || (size_t)(oend - o) < k) return -1;
            memcpy(o, p, k);
            o += k;
            p += k;
        } else {
            if (end - p < 2) return -1;
            size_t len = c - 128 + MIN_MATCH, dist = p[0] | (size_t)p[1] << 8;
            p += 2;
            if (dist == 0 || dist > (size_t)(o - dst) || (size_t)(oend - o) < len) return -1;
            const uint8_t *from = o - dist; // may overlap what it writes: a byte at a time
            for (size_t k = 0; k < len; k++) o[k] = from[k];
            o += len;
        }
    }
    return o - dst;
}

static uint64_t x = 88172645463325252ULL;

static uint64_t next(void) {
    x ^= x << 13;
    x ^= x >> 7;
    x ^= x << 17;
    return x;
}

int main(int argc, char **argv) {
    size_t n = argc > 1 ? (size_t)atol(argv[1]) : 64u << 20;
    // the text: words from a 1024-word vocabulary (the first ones the most common), and now and
    // then a phrase repeated from up to 32 KiB back
    char words[1024][10];
    size_t wlen[1024];
    for (int w = 0; w < 1024; w++) {
        wlen[w] = 2 + next() % 8;
        for (size_t k = 0; k < wlen[w]; k++) words[w][k] = (char)('a' + next() % 26);
    }
    uint8_t *text = malloc(n + 128);
    size_t len = 0;
    while (len < n) {
        uint64_t r = next();
        if (r % 16 == 0 && len >= 64) {
            size_t span = len < 32768 ? len : 32768;
            size_t dist = 1 + next() % span, count = 16 + next() % 48;
            for (size_t k = 0; k < count; k++, len++) text[len] = text[len - dist];
        } else {
            size_t w = ((r >> 8) % 1024) * ((r >> 20) % 1024) / 1024;
            memcpy(text + len, words[w], wlen[w]);
            len += wlen[w];
            switch ((r >> 40) % 16) {
            case 0: text[len++] = '.'; text[len++] = '\n'; break;
            case 1: text[len++] = ','; text[len++] = ' '; break;
            default: text[len++] = ' ';
            }
        }
    }
    uint8_t *packed = malloc(n + n / 128 + 16);
    size_t packed_len = compress(text, n, packed);
    uint8_t *back = malloc(n);
    long back_len = decompress(packed, packed_len, back, n);
    if (back_len != (long)n || memcmp(back, text, n) != 0) {
        fprintf(stderr, "round trip failed\n");
        return 1;
    }
    uint64_t check = 14695981039346656037ull;
    for (size_t i = 0; i < packed_len; i++) check = (check ^ packed[i]) * 1099511628211ull;
    printf("%zu %zu %llu\n", n, packed_len, (unsigned long long)check);
    free(text);
    free(packed);
    free(back);
    return 0;
}
