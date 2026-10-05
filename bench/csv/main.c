// csv: format n records (an int, a float with two decimals, a quoted string holding a comma) as CSV
// text, then parse them back field by field and sum them; C formats with snprintf into a growing
// buffer and parses with strtoll, strtod and memchr, reporting a bad line by return code
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static uint64_t x = 88172645463325252ULL;

static uint64_t next(void) {
    x ^= x << 13;
    x ^= x >> 7;
    x ^= x << 17;
    return x;
}

static const char *NAMES[8] = {"alpha", "bravo", "charlie", "delta", "echo", "foxtrot", "golf", "hotel"};

typedef struct { long long id; double price; const char *name; size_t name_len; } record;

// one line at *p into r, moving *p past its newline: 0, or -1 when it isn't a record
static int parse_record(const char **p, const char *end, record *r) {
    char *q;
    r->id = strtoll(*p, &q, 10);
    if (q == *p || *q != ',') return -1;
    const char *f = q + 1;
    r->price = strtod(f, &q);
    if (q == f || q + 1 >= end || q[0] != ',' || q[1] != '"') return -1;
    r->name = q + 2;
    const char *close = memchr(r->name, '"', end - r->name);
    if (!close || close + 1 >= end || close[1] != '\n') return -1;
    r->name_len = close - r->name;
    *p = close + 2;
    return 0;
}

int main(int argc, char **argv) {
    long n = argc > 1 ? atol(argv[1]) : 3000000;
    size_t len = 0, cap = 1 << 16;
    char *text = malloc(cap);
    for (long i = 0; i < n; i++) {
        long long id = (long long)(next() % 2000000001) - 1000000000;
        double price = (double)(next() % 10000000) / 100.0;
        const char *a = NAMES[next() % 8], *b = NAMES[next() % 8];
        if (len + 64 > cap) { cap *= 2; text = realloc(text, cap); }
        len += snprintf(text + len, cap - len, "%lld,%.2f,\"%s, %s\"\n", id, price, a, b);
    }
    long long ids = 0, cents = 0;
    long records = 0;
    size_t name_bytes = 0;
    const char *p = text, *end = text + len;
    while (p < end) {
        record r;
        if (parse_record(&p, end, &r) != 0) { fprintf(stderr, "bad record %ld\n", records); return 1; }
        ids += r.id;
        cents += (long long)(r.price * 100.0 + 0.5);
        name_bytes += r.name_len;
        records++;
    }
    printf("%zu bytes, %ld records\n%lld %lld %zu\n", len, records, ids, cents, name_bytes);
    free(text);
    return 0;
}
