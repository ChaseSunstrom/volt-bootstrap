// revcomp (the Benchmarks Game): the reverse complement of a 64 MiB DNA sequence in FASTA lines of
// 60 bases, done nine times between two byte buffers; prints the size, the first line and an FNV-1a
// checksum of the result
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>

static uint64_t x = 88172645463325252ULL;

static uint64_t next(void) {
    x ^= x << 13;
    x ^= x >> 7;
    x ^= x << 17;
    return x;
}

// out gets in's bases from last to first, each complemented, 60 a line
static size_t revcomp(const unsigned char *in, size_t len, unsigned char *out, const unsigned char *comp) {
    size_t o = 0, col = 0;
    for (size_t i = len; i-- > 0;) {
        unsigned char c = in[i];
        if (c == '\n') continue;
        out[o++] = comp[c];
        if (++col == 60) {
            out[o++] = '\n';
            col = 0;
        }
    }
    if (col > 0) out[o++] = '\n';
    return o;
}

int main(int argc, char **argv) {
    size_t n = argc > 1 ? (size_t)atol(argv[1]) : 67108864;
    // each IUPAC code and its complement, upper and lower case
    const char *from = "ACGTUMRWSYKVHDBNacgtumrwsykvhdbn", *to = "TGCAAKYWSRMBDHVNTGCAAKYWSRMBDHVN";
    unsigned char comp[256];
    for (int i = 0; i < 256; i++) comp[i] = (unsigned char)i;
    for (int i = 0; from[i]; i++) comp[(unsigned char)from[i]] = (unsigned char)to[i];
    // the bases: mostly ACGT, some lower case and other codes
    const char *alphabet = "ACGTACGTACGTacgtNRYKMSWBDHVnACGT";
    size_t len = n + (n + 59) / 60;
    unsigned char *a = malloc(len), *b = malloc(len);
    size_t p = 0;
    for (size_t i = 0; i < n; i++) {
        a[p++] = (unsigned char)alphabet[next() >> 59];
        if (i % 60 == 59 || i == n - 1) a[p++] = '\n';
    }
    for (int pass = 0; pass < 9; pass++) {
        revcomp(a, len, b, comp);
        unsigned char *t = a;
        a = b;
        b = t;
    }
    uint64_t check = 14695981039346656037ULL;
    for (size_t i = 0; i < len; i++) check = (check ^ a[i]) * 1099511628211ULL;
    size_t first = len < 60 ? len - 1 : 60;
    printf("%zu bases, %zu bytes\n%.*s\n%llu\n", n, len, (int)first, (const char *)a, (unsigned long long)check);
    free(a);
    free(b);
    return 0;
}
