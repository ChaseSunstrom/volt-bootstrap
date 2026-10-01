// strings: build a long text of numbered words, split it on spaces, count and join the long words
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

typedef struct { char *p; size_t len, cap; } buf;
static void put(buf *b, const char *s, size_t n) {
    if (b->len + n > b->cap) { b->cap = (b->len + n) * 2; b->p = realloc(b->p, b->cap); }
    memcpy(b->p + b->len, s, n); b->len += n;
}

int main(int argc, char **argv) {
    long n = argc > 1 ? atol(argv[1]) : 10000000;
    buf text = {0};
    char num[32];
    for (long i = 0; i < n; i++) {
        put(&text, "word", 4);
        int k = snprintf(num, sizeof num, "%ld", i * 7 % 1000003);
        put(&text, num, k);
        put(&text, " ", 1);
    }
    // split on spaces; join the words longer than 9 bytes with commas
    buf joined = {0};
    long words = 0, long_words = 0;
    size_t start = 0;
    for (size_t i = 0; i < text.len; i++) {
        if (text.p[i] == ' ') {
            size_t w = i - start;
            words++;
            if (w > 9) { if (long_words++) put(&joined, ",", 1); put(&joined, text.p + start, w); }
            start = i + 1;
        }
    }
    printf("%zu %ld %ld %zu\n", text.len, words, long_words, joined.len);
    free(text.p); free(joined.p);
    return 0;
}
