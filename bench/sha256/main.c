// sha256: the SHA-256 digest (FIPS 180-4) of a pseudo-random buffer, a 64-byte block at a time;
// C keeps the state in a struct of uint32_t arrays, with the round functions as macros
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static const uint32_t K[64] = {
    0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
    0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
    0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
    0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
    0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
    0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
    0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
    0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
};

#define ROTR(x, n) (((x) >> (n)) | ((x) << (32 - (n))))
#define CH(e, f, g) (((e) & (f)) ^ (~(e) & (g)))
#define MAJ(a, b, c) (((a) & (b)) ^ ((a) & (c)) ^ ((b) & (c)))
#define BSIG0(x) (ROTR(x, 2) ^ ROTR(x, 13) ^ ROTR(x, 22))
#define BSIG1(x) (ROTR(x, 6) ^ ROTR(x, 11) ^ ROTR(x, 25))
#define SSIG0(x) (ROTR(x, 7) ^ ROTR(x, 18) ^ ((x) >> 3))
#define SSIG1(x) (ROTR(x, 17) ^ ROTR(x, 19) ^ ((x) >> 10))

typedef struct {
    uint32_t h[8];
    uint8_t block[64]; // bytes waiting for a whole block
    size_t filled;
    uint64_t total;
} sha256;

static void sha256_init(sha256 *s) {
    static const uint32_t iv[8] = { 0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a,
                                    0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19 };
    memcpy(s->h, iv, sizeof iv);
    s->filled = 0;
    s->total = 0;
}

static void compress(uint32_t h[8], const uint8_t *b) {
    uint32_t w[64];
    for (int i = 0; i < 16; i++)
        w[i] = (uint32_t)b[4 * i] << 24 | (uint32_t)b[4 * i + 1] << 16 | (uint32_t)b[4 * i + 2] << 8 | b[4 * i + 3];
    for (int i = 16; i < 64; i++) w[i] = w[i - 16] + SSIG0(w[i - 15]) + w[i - 7] + SSIG1(w[i - 2]);
    uint32_t a = h[0], bb = h[1], c = h[2], d = h[3], e = h[4], f = h[5], g = h[6], hh = h[7];
    for (int i = 0; i < 64; i++) {
        uint32_t t1 = hh + BSIG1(e) + CH(e, f, g) + K[i] + w[i];
        uint32_t t2 = BSIG0(a) + MAJ(a, bb, c);
        hh = g; g = f; f = e; e = d + t1; d = c; c = bb; bb = a; a = t1 + t2;
    }
    h[0] += a; h[1] += bb; h[2] += c; h[3] += d; h[4] += e; h[5] += f; h[6] += g; h[7] += hh;
}

static void sha256_update(sha256 *s, const uint8_t *data, size_t n) {
    size_t i = 0;
    s->total += n;
    if (s->filled > 0) {
        while (i < n && s->filled < 64) s->block[s->filled++] = data[i++];
        if (s->filled < 64) return;
        compress(s->h, s->block);
        s->filled = 0;
    }
    for (; i + 64 <= n; i += 64) compress(s->h, data + i);
    while (i < n) s->block[s->filled++] = data[i++];
}

static void sha256_final(sha256 *s, uint8_t out[32]) {
    uint64_t bits = s->total * 8;
    uint8_t tail[72] = { 0x80 };
    size_t n = 64 - (s->filled + 8) % 64;
    if (n == 0) n = 64;
    for (int k = 0; k < 8; k++) tail[n + k] = (uint8_t)(bits >> (56 - 8 * k));
    sha256_update(s, tail, n + 8);
    for (int i = 0; i < 8; i++) {
        out[4 * i] = (uint8_t)(s->h[i] >> 24);
        out[4 * i + 1] = (uint8_t)(s->h[i] >> 16);
        out[4 * i + 2] = (uint8_t)(s->h[i] >> 8);
        out[4 * i + 3] = (uint8_t)s->h[i];
    }
}

static void hex(const uint8_t d[32], char out[65]) {
    for (int i = 0; i < 32; i++) sprintf(out + 2 * i, "%02x", d[i]);
}

static uint64_t x = 88172645463325252ULL;

static uint64_t next(void) {
    x ^= x << 13;
    x ^= x >> 7;
    x ^= x << 17;
    return x;
}

int main(int argc, char **argv) {
    size_t n = argc > 1 ? (size_t)atol(argv[1]) : 256u << 20;
    sha256 s;
    uint8_t d[32];
    char text[65];
    sha256_init(&s);
    sha256_update(&s, (const uint8_t *)"abc", 3);
    sha256_final(&s, d);
    hex(d, text);
    if (strcmp(text, "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad") != 0) {
        fprintf(stderr, "sha256(\"abc\") is wrong: %s\n", text);
        return 1;
    }
    printf("abc %s\n", text);
    uint8_t *buf = malloc(n);
    for (size_t i = 0; i < n; i++) buf[i] = (uint8_t)(next() >> 56);
    sha256_init(&s);
    sha256_update(&s, buf, n);
    sha256_final(&s, d);
    hex(d, text);
    printf("%zu %s\n", n, text);
    free(buf);
    return 0;
}
