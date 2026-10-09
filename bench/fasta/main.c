// fasta (the Benchmarks Game): generate three DNA sequences, n*2 bases repeating the ALU string, then
// n*3 and n*5 bases drawn by a linear congruential generator from cumulative probability tables, in
// FASTA lines of 60; prints each one's header, length and an FNV-1a checksum of its lines in place of
// the text. C builds the cumulative tables when it starts
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

typedef struct { char c; double p; } acid;

static const char ALU[] = "GGCCGGGCGCGGTGGCTCACGCCTGTAATCCCAGCACTTTGGGAGGCCGAGGCGGGCGGATCACCTGAGGTCAGGAGTTCGAGACCAGCC"
                          "TGGCCAACATGGTGAAACCCCGTCTCTACTAAAAATACAAAAATTAGCCGGGCGTGGTGGCGCGCGCCTGTAATCCCAGCTACTCGGGAG"
                          "GCTGAGGCAGGAGAATCGCTTGAACCCGGGAGGCGGAGGTTGCAGTGAGCCGAGATCGCGCCACTGCACTCCAGCCTGGGCGACAGAGCGA"
                          "GACTCCGTCTCAAAAA";

static acid IUB[] = {
    { 'a', 0.27 }, { 'c', 0.12 }, { 'g', 0.12 }, { 't', 0.27 }, { 'B', 0.02 }, { 'D', 0.02 }, { 'H', 0.02 }, { 'K', 0.02 },
    { 'M', 0.02 }, { 'N', 0.02 }, { 'R', 0.02 }, { 'S', 0.02 }, { 'V', 0.02 }, { 'W', 0.02 }, { 'Y', 0.02 },
};

static acid HOMO_SAPIENS[] = {
    { 'a', 0.3029549426680 }, { 'c', 0.1979883004921 }, { 'g', 0.1975473066391 }, { 't', 0.3015094502008 },
};

// each p becomes the sum of the ones up to it
static void cumulative(acid *t, int n) {
    double sum = 0;
    for (int i = 0; i < n; i++) {
        sum += t[i].p;
        t[i].p = sum;
    }
}

#define IM 139968
#define IA 3877
#define IC 29573

static uint32_t seed = 42;

static double random_unit(void) {
    seed = (seed * IA + IC) % IM;
    return (double)seed / IM;
}

static uint64_t fnv(uint64_t h, const char *s, size_t n) {
    for (size_t i = 0; i < n; i++) h = (h ^ (unsigned char)s[i]) * 1099511628211ULL;
    return h;
}

static void repeat(const char *header, const char *s, size_t n) {
    size_t len = strlen(s), pos = 0;
    char line[61];
    uint64_t h = 14695981039346656037ULL;
    for (size_t done = 0; done < n;) {
        size_t m = n - done < 60 ? n - done : 60;
        for (size_t i = 0; i < m; i++) {
            line[i] = s[pos];
            if (++pos == len) pos = 0;
        }
        line[m] = '\n';
        h = fnv(h, line, m + 1);
        done += m;
    }
    printf("%s: %zu bases, checksum %llu\n", header, n, (unsigned long long)h);
}

static void random_bases(const char *header, const acid *t, int count, size_t n) {
    char line[61];
    uint64_t h = 14695981039346656037ULL;
    for (size_t done = 0; done < n;) {
        size_t m = n - done < 60 ? n - done : 60;
        for (size_t i = 0; i < m; i++) {
            double r = random_unit();
            int k = 0;
            while (k < count - 1 && r >= t[k].p) k++;
            line[i] = t[k].c;
        }
        line[m] = '\n';
        h = fnv(h, line, m + 1);
        done += m;
    }
    printf("%s: %zu bases, checksum %llu\n", header, n, (unsigned long long)h);
}

int main(int argc, char **argv) {
    size_t n = argc > 1 ? (size_t)atol(argv[1]) : 10000000;
    cumulative(IUB, 15);
    cumulative(HOMO_SAPIENS, 4);
    repeat(">ONE Homo sapiens alu", ALU, n * 2);
    random_bases(">TWO IUB ambiguity codes", IUB, 15, n * 3);
    random_bases(">THREE Homo sapiens frequency", HOMO_SAPIENS, 4, n * 5);
    return 0;
}
