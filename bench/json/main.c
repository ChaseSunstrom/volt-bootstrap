// json: generate a JSON array of n objects (nested arrays and objects, escaped strings, ints and
// decimals) as text, parse it into a tree, then walk the tree for counts and sums; C hand-writes a
// recursive-descent parser into tagged unions with malloc'd arrays and strings, numbers by strtod,
// and walks with a switch
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

// ---------- the text ----------

typedef struct { char *p; size_t len, cap; } buf;

static void put(buf *b, const char *s, size_t n) {
    if (b->len + n > b->cap) {
        b->cap = (b->len + n) * 2;
        b->p = realloc(b->p, b->cap);
    }
    memcpy(b->p + b->len, s, n);
    b->len += n;
}
static void puts_(buf *b, const char *s) { put(b, s, strlen(s)); }
static void put_int(buf *b, long long v) {
    char t[24];
    put(b, t, snprintf(t, sizeof t, "%lld", v));
}

static const char *WORDS[8] = {"alpha", "bravo", "charlie", "delta", "echo", "foxtrot", "golf", "hotel"};
static const char *ESCAPES[5] = {"\\\"", "\\\\", "\\n", "\\t", "\\u00e9"};

// a string of 2 to 5 pieces, a quarter of them escapes
static void put_name(buf *b) {
    puts_(b, "\"");
    long pieces = 2 + next() % 4;
    for (long k = 0; k < pieces; k++) {
        if (next() % 4 == 0) puts_(b, ESCAPES[next() % 5]);
        else puts_(b, WORDS[next() % 8]);
    }
    puts_(b, "\"");
}

static void put_object(buf *b, long i) {
    char t[32];
    puts_(b, "{\"id\":");
    put_int(b, i);
    puts_(b, ",\"name\":");
    put_name(b);
    long cents = next() % 1000000;
    put(b, t, snprintf(t, sizeof t, ",\"score\":%ld.%02ld,\"tags\":[", cents / 100, cents % 100));
    long tags = next() % 5;
    for (long k = 0; k < tags; k++) {
        if (k > 0) puts_(b, ",");
        puts_(b, "\"");
        puts_(b, WORDS[next() % 8]);
        puts_(b, "\"");
    }
    puts_(b, "],\"pos\":[");
    for (int k = 0; k < 3; k++) {
        if (k > 0) puts_(b, ",");
        put_int(b, (long long)(next() % 2000001) - 1000000);
    }
    puts_(b, next() % 2 ? "],\"active\":true" : "],\"active\":false");
    puts_(b, ",\"meta\":{\"level\":");
    put_int(b, next() % 10);
    put(b, t, snprintf(t, sizeof t, ",\"ratio\":0.%03ld,\"note\":", (long)(next() % 1000)));
    if (next() % 3 == 0) puts_(b, "null");
    else put_name(b);
    puts_(b, "}}");
}

// ---------- the tree ----------

typedef enum { J_NULL, J_BOOL, J_NUM, J_STR, J_ARR, J_OBJ } kind;
typedef struct value value;
typedef struct member member;

struct value {
    kind kind;
    union {
        int b;
        double num;
        struct { char *p; size_t len; } str;
        struct { value *items; size_t len, cap; } arr;
        struct { member *items; size_t len, cap; } obj;
    };
};

struct member {
    char *name;
    size_t name_len;
    value item;
};

static void free_value(value *v) {
    switch (v->kind) {
    case J_STR: free(v->str.p); break;
    case J_ARR:
        for (size_t i = 0; i < v->arr.len; i++) free_value(&v->arr.items[i]);
        free(v->arr.items);
        break;
    case J_OBJ:
        for (size_t i = 0; i < v->obj.len; i++) { free(v->obj.items[i].name); free_value(&v->obj.items[i].item); }
        free(v->obj.items);
        break;
    default: break;
    }
}

// ---------- parsing: each function returns 0, or -1 for text that isn't JSON ----------

typedef struct { const char *p, *end; } parser;

static void skip_space(parser *ps) {
    while (ps->p < ps->end && (*ps->p == ' ' || *ps->p == '\t' || *ps->p == '\n' || *ps->p == '\r')) ps->p++;
}

static int hex4(const char *s, unsigned *out) {
    unsigned v = 0;
    for (int i = 0; i < 4; i++) {
        char c = s[i];
        v <<= 4;
        if (c >= '0' && c <= '9') v |= c - '0';
        else if (c >= 'a' && c <= 'f') v |= c - 'a' + 10;
        else if (c >= 'A' && c <= 'F') v |= c - 'A' + 10;
        else return -1;
    }
    *out = v;
    return 0;
}

static size_t put_utf8(char *o, unsigned cp) {
    if (cp < 0x80) { o[0] = cp; return 1; }
    if (cp < 0x800) { o[0] = 0xC0 | cp >> 6; o[1] = 0x80 | (cp & 0x3F); return 2; }
    if (cp < 0x10000) { o[0] = 0xE0 | cp >> 12; o[1] = 0x80 | ((cp >> 6) & 0x3F); o[2] = 0x80 | (cp & 0x3F); return 3; }
    o[0] = 0xF0 | cp >> 18; o[1] = 0x80 | ((cp >> 12) & 0x3F); o[2] = 0x80 | ((cp >> 6) & 0x3F); o[3] = 0x80 | (cp & 0x3F);
    return 4;
}

// the string literal at ps->p (its opening quote), unescaped into a malloc'd buffer: escapes only
// shrink, so the raw length is enough
static int parse_string(parser *ps, char **out, size_t *len) {
    const char *s = ++ps->p, *e = s;
    while (e < ps->end && *e != '"') e += *e == '\\' ? 2 : 1;
    if (e >= ps->end) return -1;
    char *o = malloc(e - s + 1);
    size_t n = 0;
    while (s < e) {
        unsigned char c = *s;
        if (c < 0x20) goto bad;
        if (c != '\\') { o[n++] = c; s++; continue; }
        char esc = s[1];
        s += 2;
        switch (esc) {
        case 'n': o[n++] = '\n'; break;
        case 't': o[n++] = '\t'; break;
        case 'r': o[n++] = '\r'; break;
        case 'b': o[n++] = '\b'; break;
        case 'f': o[n++] = '\f'; break;
        case '"': case '\\': case '/': o[n++] = esc; break;
        case 'u': {
            unsigned cp, lo;
            if (e - s < 4 || hex4(s, &cp)) goto bad;
            s += 4;
            // a surrogate pair is one code point
            if (cp >= 0xD800 && cp < 0xDC00 && e - s >= 6 && s[0] == '\\' && s[1] == 'u' && !hex4(s + 2, &lo) && lo >= 0xDC00 && lo < 0xE000) {
                cp = 0x10000 + ((cp - 0xD800) << 10) + (lo - 0xDC00);
                s += 6;
            }
            n += put_utf8(o + n, cp);
            break;
        }
        default: goto bad;
        }
    }
    o[n] = 0;
    ps->p = e + 1;
    *out = o;
    *len = n;
    return 0;
bad:
    free(o);
    return -1;
}

static int word(parser *ps, const char *w, size_t n) {
    if ((size_t)(ps->end - ps->p) >= n && memcmp(ps->p, w, n) == 0) { ps->p += n; return 1; }
    return 0;
}

// the value at ps->p into *out; on failure *out still holds what was built, for free_value
static int parse_value(parser *ps, value *out, int depth) {
    out->kind = J_NULL;
    if (depth > 512) return -1;
    skip_space(ps);
    if (ps->p >= ps->end) return -1;
    char c = *ps->p;
    if (c == '[') {
        ps->p++;
        out->kind = J_ARR;
        out->arr.items = NULL;
        out->arr.len = out->arr.cap = 0;
        skip_space(ps);
        if (ps->p < ps->end && *ps->p == ']') { ps->p++; return 0; }
        for (;;) {
            if (out->arr.len == out->arr.cap) {
                out->arr.cap = out->arr.cap ? out->arr.cap * 2 : 4;
                out->arr.items = realloc(out->arr.items, out->arr.cap * sizeof(value));
            }
            if (parse_value(ps, &out->arr.items[out->arr.len++], depth + 1)) return -1;
            skip_space(ps);
            if (ps->p < ps->end && *ps->p == ',') ps->p++;
            else if (ps->p < ps->end && *ps->p == ']') { ps->p++; return 0; }
            else return -1;
        }
    }
    if (c == '{') {
        ps->p++;
        out->kind = J_OBJ;
        out->obj.items = NULL;
        out->obj.len = out->obj.cap = 0;
        skip_space(ps);
        if (ps->p < ps->end && *ps->p == '}') { ps->p++; return 0; }
        for (;;) {
            skip_space(ps);
            if (ps->p >= ps->end || *ps->p != '"') return -1;
            char *name;
            size_t name_len;
            if (parse_string(ps, &name, &name_len)) return -1;
            skip_space(ps);
            if (ps->p >= ps->end || *ps->p != ':') { free(name); return -1; }
            ps->p++;
            if (out->obj.len == out->obj.cap) {
                out->obj.cap = out->obj.cap ? out->obj.cap * 2 : 4;
                out->obj.items = realloc(out->obj.items, out->obj.cap * sizeof(member));
            }
            member *m = &out->obj.items[out->obj.len++];
            m->name = name;
            m->name_len = name_len;
            if (parse_value(ps, &m->item, depth + 1)) return -1;
            skip_space(ps);
            if (ps->p < ps->end && *ps->p == ',') ps->p++;
            else if (ps->p < ps->end && *ps->p == '}') { ps->p++; return 0; }
            else return -1;
        }
    }
    if (c == '"') {
        out->kind = J_STR;
        if (parse_string(ps, &out->str.p, &out->str.len)) { out->kind = J_NULL; return -1; }
        return 0;
    }
    if (word(ps, "true", 4)) { out->kind = J_BOOL; out->b = 1; return 0; }
    if (word(ps, "false", 5)) { out->kind = J_BOOL; out->b = 0; return 0; }
    if (word(ps, "null", 4)) return 0;
    char *end;
    out->num = strtod(ps->p, &end);
    if (end == ps->p) return -1;
    out->kind = J_NUM;
    ps->p = end;
    return 0;
}

static int json_parse(const char *text, size_t len, value *out) {
    parser ps = {text, text + len};
    if (parse_value(&ps, out, 0)) { free_value(out); return -1; }
    skip_space(&ps);
    if (ps.p != ps.end) { free_value(out); return -1; }
    return 0;
}

// an object's member called key, or NULL
static const value *json_get(const value *v, const char *key) {
    if (v->kind != J_OBJ) return NULL;
    size_t n = strlen(key);
    for (size_t i = 0; i < v->obj.len; i++)
        if (v->obj.items[i].name_len == n && memcmp(v->obj.items[i].name, key, n) == 0) return &v->obj.items[i].item;
    return NULL;
}

// ---------- walking ----------

typedef struct { long objects, arrays, strings, numbers, trues, nulls, string_bytes; } stats;

static void walk(const value *v, stats *s) {
    switch (v->kind) {
    case J_NULL: s->nulls++; break;
    case J_BOOL: if (v->b) s->trues++; break;
    case J_NUM: s->numbers++; break;
    case J_STR: s->strings++; s->string_bytes += v->str.len; break;
    case J_ARR:
        s->arrays++;
        for (size_t i = 0; i < v->arr.len; i++) walk(&v->arr.items[i], s);
        break;
    case J_OBJ:
        s->objects++;
        for (size_t i = 0; i < v->obj.len; i++) walk(&v->obj.items[i].item, s);
        break;
    }
}

int main(int argc, char **argv) {
    long n = argc > 1 ? atol(argv[1]) : 400000;
    buf text = {0};
    puts_(&text, "[");
    for (long i = 0; i < n; i++) {
        if (i > 0) puts_(&text, ",\n");
        put_object(&text, i);
    }
    puts_(&text, "]\n");
    value doc;
    if (json_parse(text.p, text.len, &doc)) { fprintf(stderr, "not JSON\n"); return 1; }
    stats s = {0};
    walk(&doc, &s);
    long long ids = 0, cents = 0;
    for (size_t i = 0; i < doc.arr.len; i++) {
        const value *id = json_get(&doc.arr.items[i], "id"), *score = json_get(&doc.arr.items[i], "score");
        if (id && id->kind == J_NUM) ids += (long long)id->num;
        if (score && score->kind == J_NUM) cents += (long long)(score->num * 100.0 + 0.5);
    }
    printf("%zu bytes: %ld objects, %ld arrays, %ld strings, %ld numbers\n", text.len, s.objects, s.arrays, s.strings, s.numbers);
    printf("%ld string bytes, %ld true, %ld null\n", s.string_bytes, s.trues, s.nulls);
    printf("%lld %lld\n", ids, cents);
    free_value(&doc);
    free(text.p);
    return 0;
}
