// lexer: generate a large source text in a C-like toy language, tokenize it ten times, and count the
// tokens by kind (plus a checksum of the identifiers' lengths); C scans with a pointer and returns a struct
// token holding an enum kind and a pointer and length into the text
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

typedef enum { T_IDENT, T_KEYWORD, T_INT, T_FLOAT, T_STRING, T_OP, T_PUNCT, T_COMMENT, T_ERROR, T_EOF } kind;
static const char *const KIND_NAMES[] = { "ident", "keyword", "int", "float", "string", "op", "punct", "comment", "error" };

typedef struct {
    kind kind;
    const char *start;
    size_t len;
} token;

typedef struct {
    const char *p, *end;
} lexer;

static const struct { const char *text; size_t len; } KEYWORDS[] = {
    { "fn", 2 }, { "let", 3 }, { "if", 2 }, { "else", 4 }, { "while", 5 },
    { "for", 3 }, { "return", 6 }, { "struct", 6 }, { "true", 4 }, { "false", 5 },
};

static int is_alpha(char c) { return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || c == '_'; }
static int is_digit(char c) { return c >= '0' && c <= '9'; }

static int is_keyword(const char *s, size_t len) {
    for (size_t i = 0; i < sizeof KEYWORDS / sizeof KEYWORDS[0]; i++)
        if (KEYWORDS[i].len == len && memcmp(KEYWORDS[i].text, s, len) == 0) return 1;
    return 0;
}

static token next_token(lexer *lx) {
    const char *p = lx->p, *end = lx->end;
    while (p < end && (*p == ' ' || *p == '\t' || *p == '\n' || *p == '\r')) p++;
    const char *start = p;
    if (p == end) return (token){ T_EOF, p, 0 };
    char c = *p++;
    kind k;
    if (is_alpha(c)) {
        while (p < end && (is_alpha(*p) || is_digit(*p))) p++;
        k = is_keyword(start, p - start) ? T_KEYWORD : T_IDENT;
    } else if (is_digit(c)) {
        k = T_INT;
        while (p < end && is_digit(*p)) p++;
        if (p + 1 < end && *p == '.' && is_digit(p[1])) {
            k = T_FLOAT;
            p++;
            while (p < end && is_digit(*p)) p++;
        }
        if (p < end && (*p == 'e' || *p == 'E')) {
            const char *q = p + 1;
            if (q < end && (*q == '+' || *q == '-')) q++;
            if (q < end && is_digit(*q)) {
                k = T_FLOAT;
                p = q;
                while (p < end && is_digit(*p)) p++;
            }
        }
    } else if (c == '"') {
        while (p < end && *p != '"') p += *p == '\\' && p + 1 < end ? 2 : 1;
        if (p < end) p++;
        k = T_STRING;
    } else if (c == '/' && p < end && *p == '/') {
        while (p < end && *p != '\n') p++;
        k = T_COMMENT;
    } else if (c == '/' && p < end && *p == '*') {
        p++;
        while (p + 1 < end && !(p[0] == '*' && p[1] == '/')) p++;
        p = p + 1 < end ? p + 2 : end;
        k = T_COMMENT;
    } else {
        switch (c) {
        case '(': case ')': case '{': case '}': case '[': case ']': case ';': case ',': case '.':
            k = T_PUNCT;
            break;
        case '=': case '!': case '<': case '>': case '+': case '*': case '/': case '%':
            if (p < end && *p == '=') p++; // ==, !=, <=, >=, +=, *=, /=, %=
            k = T_OP;
            break;
        case '-':
            if (p < end && (*p == '=' || *p == '>')) p++;
            k = T_OP;
            break;
        case '&': case '|':
            if (p < end && *p == c) p++; // && and ||
            k = T_OP;
            break;
        default:
            k = T_ERROR;
        }
    }
    lx->p = p;
    return (token){ k, start, (size_t)(p - start) };
}

// ---- the source text ----

typedef struct {
    char *p;
    size_t len, cap;
} buf;

static void put(buf *b, const char *s) {
    size_t n = strlen(s);
    if (b->len + n > b->cap) {
        b->cap = b->cap * 2 + n;
        b->p = realloc(b->p, b->cap);
    }
    memcpy(b->p + b->len, s, n);
    b->len += n;
}

static void put_uint(buf *b, uint64_t v) {
    char digits[24];
    snprintf(digits, sizeof digits, "%llu", (unsigned long long)v);
    put(b, digits);
}

static uint64_t x = 88172645463325252ULL;

static uint64_t next(void) {
    x ^= x << 13;
    x ^= x >> 7;
    x ^= x << 17;
    return x;
}

static const char *const NAMES[] = { "count", "index", "value", "node", "buf", "len", "total", "x",
                                     "y", "result", "item", "next_one", "left", "right", "data", "i" };
static const char *const WORDS[] = { "the", "loop", "ends", "when", "it", "reaches", "zero", "todo" };
static const char *const PIECES[] = { "hello", "world", "\\n", "\\t", "\\\"", "\\\\", " ", "value: " };
static const char *const OPS[] = { "+", "-", "*", "/", "%" };
static const char *const CMPS[] = { "==", "!=", "<", "<=", ">", ">=" };

static void gen_ident(buf *b) {
    uint64_t r = next();
    put(b, NAMES[r % 16]);
    if ((r >> 8) % 4 == 0) {
        put(b, "_");
        put_uint(b, (r >> 16) % 1000);
    }
}

static void gen_int(buf *b) { put_uint(b, next() % 100000); }

static void gen_float(buf *b) {
    uint64_t r = next();
    put_uint(b, r % 1000);
    put(b, ".");
    put_uint(b, (r >> 20) % 1000);
    if ((r >> 40) % 4 == 0) {
        put(b, "e");
        put_uint(b, (r >> 50) % 20);
    }
}

static void gen_string(buf *b) {
    uint64_t r = next();
    put(b, "\"");
    for (uint64_t k = 0; k < 1 + r % 4; k++) put(b, PIECES[(r >> (8 + 3 * k)) % 8]);
    put(b, "\"");
}

static void gen_words(buf *b) {
    uint64_t r = next();
    for (uint64_t k = 0; k < 2 + r % 6; k++) {
        put(b, " ");
        put(b, WORDS[(r >> (8 + 3 * k)) % 8]);
    }
}

static void gen_expr(buf *b) {
    uint64_t r = next();
    switch (r % 4) {
    case 0: gen_ident(b); break;
    case 1: gen_int(b); break;
    case 2: gen_float(b); break;
    default:
        gen_ident(b);
        put(b, " ");
        put(b, OPS[(r >> 8) % 5]);
        put(b, " ");
        gen_int(b);
    }
}

static void gen_statement(buf *b) {
    uint64_t r = next();
    switch (r % 8) {
    case 0:
        put(b, "let "); gen_ident(b); put(b, " = "); gen_expr(b); put(b, ";\n");
        break;
    case 1:
        put(b, "if ("); gen_expr(b); put(b, " "); put(b, CMPS[(r >> 8) % 6]); put(b, " "); gen_expr(b);
        put(b, ") {\n    "); gen_ident(b); put(b, " = "); gen_expr(b);
        put(b, ";\n} else {\n    return "); gen_expr(b); put(b, ";\n}\n");
        break;
    case 2:
        put(b, "while ("); gen_ident(b); put(b, " "); put(b, CMPS[(r >> 8) % 6]); put(b, " "); gen_int(b);
        put(b, " && "); gen_ident(b); put(b, " != "); gen_int(b); put(b, " || !"); gen_ident(b);
        put(b, ") {\n    "); gen_ident(b); put(b, " += "); gen_int(b); put(b, ";\n}\n");
        break;
    case 3:
        put(b, "return "); gen_string(b); put(b, ";\n");
        break;
    case 4:
        put(b, "//"); gen_words(b); put(b, "\n");
        break;
    case 5:
        put(b, "/*"); gen_words(b); put(b, " */\n");
        break;
    case 6:
        gen_ident(b); put(b, "("); gen_expr(b); put(b, ", "); gen_expr(b); put(b, ");\n");
        break;
    default:
        put(b, "fn "); gen_ident(b); put(b, "("); gen_ident(b); put(b, ", "); gen_ident(b); put(b, ") -> ");
        gen_ident(b); put(b, " {\n    let "); gen_ident(b); put(b, " = "); gen_float(b); put(b, " * ");
        gen_ident(b); put(b, " - "); gen_int(b); put(b, ";\n}\n");
    }
}

int main(int argc, char **argv) {
    size_t n = argc > 1 ? (size_t)atol(argv[1]) : 32u << 20;
    buf src = { 0 };
    while (src.len < n) gen_statement(&src);
    size_t counts[T_EOF] = { 0 }, total = 0;
    uint64_t check = 0;
    for (int pass = 0; pass < 10; pass++) {
        lexer lx = { src.p, src.p + src.len };
        for (token t = next_token(&lx); t.kind != T_EOF; t = next_token(&lx)) {
            counts[t.kind]++;
            total++;
            if (t.kind == T_IDENT) check = check * 31 + t.len;
        }
    }
    printf("%zu bytes, %zu tokens\n", src.len, total);
    for (int k = 0; k < T_EOF; k++) printf("%s %zu\n", KIND_NAMES[k], counts[k]);
    printf("identifier checksum %llu\n", (unsigned long long)check);
    free(src.p);
    return 0;
}
