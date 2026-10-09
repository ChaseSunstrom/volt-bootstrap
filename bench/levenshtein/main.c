// levenshtein: edit distances between many pairs of strings, each a random string of 64 to 191
// letters and a copy with random substitutions, deletions and insertions, by the dynamic program
// over one row; prints the number of pairs, the sum and the largest of the distances, and a checksum
// of them all
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

static uint32_t distance(const char *a, size_t la, const char *b, size_t lb, uint32_t *row) {
    for (size_t j = 0; j <= lb; j++) row[j] = (uint32_t)j;
    for (size_t i = 1; i <= la; i++) {
        uint32_t diag = row[0];
        row[0] = (uint32_t)i;
        for (size_t j = 1; j <= lb; j++) {
            uint32_t up = row[j];
            uint32_t best = diag + (a[i - 1] != b[j - 1]);
            if (up + 1 < best) best = up + 1;
            if (row[j - 1] + 1 < best) best = row[j - 1] + 1;
            row[j] = best;
            diag = up;
        }
    }
    return row[lb];
}

int main(int argc, char **argv) {
    size_t pairs = argc > 1 ? (size_t)atol(argv[1]) : 40000;
    const char *letters = "abcdefgh";
    char a[192], b[384];
    uint32_t row[385];
    uint64_t total = 0, check = 0;
    uint32_t most = 0;
    for (size_t p = 0; p < pairs; p++) {
        size_t la = 64 + next() % 128, lb = 0;
        for (size_t i = 0; i < la; i++) a[i] = letters[next() % 8];
        // b: a with about one letter in 8 changed, one in 16 dropped and one in 16 inserted
        for (size_t i = 0; i < la; i++) {
            uint64_t r = next() % 16;
            if (r == 0) continue;
            if (r == 1) b[lb++] = letters[next() % 8];
            b[lb++] = r == 2 || r == 3 ? letters[next() % 8] : a[i];
        }
        uint32_t d = distance(a, la, b, lb, row);
        total += d;
        if (d > most) most = d;
        check = check * 31 + d;
    }
    printf("%zu pairs, total distance %llu, largest %u\n", pairs, (unsigned long long)total, most);
    printf("checksum %llu\n", (unsigned long long)check);
    return 0;
}
