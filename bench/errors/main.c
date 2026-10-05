// errors: lines of comma-separated numbers, about 1 in 100 malformed, parsed through three layers of
// calls (parse_list -> parse_number -> parse_digits), many rounds; the caller counts the lines that
// fail and sums the rest. C returns a status code and passes the value back through an out-param
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>

typedef enum { PARSE_OK, PARSE_EMPTY, PARSE_BAD_DIGIT } parse_status;
typedef struct { const char *text; size_t len, pos; } parser;

// the digits up to the next ',' or '\n'
static parse_status parse_digits(parser *p, int64_t *out) {
    size_t start = p->pos;
    int64_t v = 0;
    while (p->pos < p->len) {
        char c = p->text[p->pos];
        if (c == ',' || c == '\n') break;
        if (c < '0' || c > '9') return PARSE_BAD_DIGIT;
        v = v * 10 + (c - '0');
        p->pos++;
    }
    if (p->pos == start) return PARSE_EMPTY;
    *out = v;
    return PARSE_OK;
}

static parse_status parse_number(parser *p, int64_t *out) {
    if (p->pos < p->len && p->text[p->pos] == '-') {
        p->pos++;
        int64_t v;
        parse_status st = parse_digits(p, &v);
        if (st != PARSE_OK) return st;
        *out = -v;
        return PARSE_OK;
    }
    return parse_digits(p, out);
}

// one line's numbers: their sum
static parse_status parse_list(parser *p, int64_t *out) {
    int64_t sum = 0;
    for (;;) {
        int64_t v;
        parse_status st = parse_number(p, &v);
        if (st != PARSE_OK) return st;
        sum += v;
        if (p->pos >= p->len || p->text[p->pos] == '\n') break;
        p->pos++;
    }
    p->pos++;
    *out = sum;
    return PARSE_OK;
}

static void skip_line(parser *p) {
    while (p->pos < p->len && p->text[p->pos] != '\n') p->pos++;
    p->pos++;
}

static uint64_t rng = 88172645463325252ULL;
static uint64_t next(void) {
    rng ^= rng << 13;
    rng ^= rng >> 7;
    rng ^= rng << 17;
    return rng;
}

int main(int argc, char **argv) {
    long rounds = argc > 1 ? atol(argv[1]) : 1000;
    size_t lines = 20000;
    // at most 10 fields a line, each at most "-999999x,"
    char *text = malloc(lines * 91);
    size_t len = 0;
    for (size_t i = 0; i < lines; i++) {
        uint64_t count = 1 + next() % 10;
        for (uint64_t k = 0; k < count; k++) {
            if (k > 0) text[len++] = ',';
            uint64_t r = next() % 200;
            if (r == 0) continue; // an empty field
            if (r % 4 == 2) text[len++] = '-';
            len += sprintf(text + len, "%llu", (unsigned long long)(next() % 1000000));
            if (r == 1) text[len++] = 'x'; // a stray letter
        }
        text[len++] = '\n';
    }
    int64_t total = 0;
    long failures = 0;
    for (long round = 0; round < rounds; round++) {
        parser p = {text, len, 0};
        while (p.pos < p.len) {
            int64_t sum;
            if (parse_list(&p, &sum) != PARSE_OK) {
                failures++;
                skip_line(&p);
                continue;
            }
            total += sum;
        }
    }
    printf("%zu bytes, %lld total, %ld failures\n", len, (long long)total, failures);
    free(text);
    return 0;
}
