// lexer: generate a large source text in a C-like toy language, tokenize it ten times, and count the
// tokens by kind (plus a checksum of the identifiers' lengths); C++ scans a std::string_view by index
// in a Lexer class, and a token is an enum class kind plus a std::string_view of its text
#include <algorithm>
#include <array>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <string>
#include <string_view>

enum class Kind { Ident, Keyword, Int, Float, String, Op, Punct, Comment, Error, Eof };
constexpr std::array<const char *, 9> KIND_NAMES = { "ident", "keyword", "int", "float", "string", "op", "punct", "comment", "error" };

struct Token {
    Kind kind;
    std::string_view text;
};

constexpr std::array<std::string_view, 10> KEYWORDS = { "fn", "let", "if", "else", "while", "for", "return", "struct", "true", "false" };

static bool is_alpha(char c) { return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || c == '_'; }
static bool is_digit(char c) { return c >= '0' && c <= '9'; }

class Lexer {
    std::string_view src;
    size_t pos = 0;

    bool at(size_t i, char c) const { return i < src.size() && src[i] == c; }
    bool digit_at(size_t i) const { return i < src.size() && is_digit(src[i]); }

public:
    explicit Lexer(std::string_view s) : src(s) {}

    Token next() {
        size_t p = pos, n = src.size();
        while (p < n && (src[p] == ' ' || src[p] == '\t' || src[p] == '\n' || src[p] == '\r')) p++;
        size_t start = p;
        if (p == n) return { Kind::Eof, {} };
        char c = src[p++];
        Kind k;
        if (is_alpha(c)) {
            while (p < n && (is_alpha(src[p]) || is_digit(src[p]))) p++;
            k = std::ranges::find(KEYWORDS, src.substr(start, p - start)) != KEYWORDS.end() ? Kind::Keyword : Kind::Ident;
        } else if (is_digit(c)) {
            k = Kind::Int;
            while (digit_at(p)) p++;
            if (at(p, '.') && digit_at(p + 1)) {
                k = Kind::Float;
                p++;
                while (digit_at(p)) p++;
            }
            if (at(p, 'e') || at(p, 'E')) {
                size_t q = p + 1;
                if (at(q, '+') || at(q, '-')) q++;
                if (digit_at(q)) {
                    k = Kind::Float;
                    p = q;
                    while (digit_at(p)) p++;
                }
            }
        } else if (c == '"') {
            while (p < n && src[p] != '"') p += src[p] == '\\' && p + 1 < n ? 2 : 1;
            if (p < n) p++;
            k = Kind::String;
        } else if (c == '/' && at(p, '/')) {
            while (p < n && src[p] != '\n') p++;
            k = Kind::Comment;
        } else if (c == '/' && at(p, '*')) {
            p++;
            while (p + 1 < n && !(src[p] == '*' && src[p + 1] == '/')) p++;
            p = p + 1 < n ? p + 2 : n;
            k = Kind::Comment;
        } else {
            switch (c) {
            case '(': case ')': case '{': case '}': case '[': case ']': case ';': case ',': case '.':
                k = Kind::Punct;
                break;
            case '=': case '!': case '<': case '>': case '+': case '*': case '/': case '%':
                if (at(p, '=')) p++; // ==, !=, <=, >=, +=, *=, /=, %=
                k = Kind::Op;
                break;
            case '-':
                if (at(p, '=') || at(p, '>')) p++;
                k = Kind::Op;
                break;
            case '&': case '|':
                if (at(p, c)) p++; // && and ||
                k = Kind::Op;
                break;
            default:
                k = Kind::Error;
            }
        }
        pos = p;
        return { k, src.substr(start, p - start) };
    }
};

// ---- the source text ----

static uint64_t x = 88172645463325252ULL;

static uint64_t next() {
    x ^= x << 13;
    x ^= x >> 7;
    x ^= x << 17;
    return x;
}

constexpr std::array<std::string_view, 16> NAMES = { "count", "index", "value", "node", "buf", "len", "total", "x",
                                                     "y", "result", "item", "next_one", "left", "right", "data", "i" };
constexpr std::array<std::string_view, 8> WORDS = { "the", "loop", "ends", "when", "it", "reaches", "zero", "todo" };
constexpr std::array<std::string_view, 8> PIECES = { "hello", "world", "\\n", "\\t", "\\\"", "\\\\", " ", "value: " };
constexpr std::array<std::string_view, 5> OPS = { "+", "-", "*", "/", "%" };
constexpr std::array<std::string_view, 6> CMPS = { "==", "!=", "<", "<=", ">", ">=" };

static void gen_ident(std::string &b) {
    uint64_t r = next();
    b += NAMES[r % 16];
    if ((r >> 8) % 4 == 0) {
        b += '_';
        b += std::to_string((r >> 16) % 1000);
    }
}

static void gen_int(std::string &b) { b += std::to_string(next() % 100000); }

static void gen_float(std::string &b) {
    uint64_t r = next();
    b += std::to_string(r % 1000);
    b += '.';
    b += std::to_string((r >> 20) % 1000);
    if ((r >> 40) % 4 == 0) {
        b += 'e';
        b += std::to_string((r >> 50) % 20);
    }
}

static void gen_string(std::string &b) {
    uint64_t r = next();
    b += '"';
    for (uint64_t k = 0; k < 1 + r % 4; k++) b += PIECES[(r >> (8 + 3 * k)) % 8];
    b += '"';
}

static void gen_words(std::string &b) {
    uint64_t r = next();
    for (uint64_t k = 0; k < 2 + r % 6; k++) {
        b += ' ';
        b += WORDS[(r >> (8 + 3 * k)) % 8];
    }
}

static void gen_expr(std::string &b) {
    uint64_t r = next();
    switch (r % 4) {
    case 0: gen_ident(b); break;
    case 1: gen_int(b); break;
    case 2: gen_float(b); break;
    default:
        gen_ident(b);
        b += ' ';
        b += OPS[(r >> 8) % 5];
        b += ' ';
        gen_int(b);
    }
}

static void gen_statement(std::string &b) {
    uint64_t r = next();
    switch (r % 8) {
    case 0:
        b += "let "; gen_ident(b); b += " = "; gen_expr(b); b += ";\n";
        break;
    case 1:
        b += "if ("; gen_expr(b); b += ' '; b += CMPS[(r >> 8) % 6]; b += ' '; gen_expr(b);
        b += ") {\n    "; gen_ident(b); b += " = "; gen_expr(b);
        b += ";\n} else {\n    return "; gen_expr(b); b += ";\n}\n";
        break;
    case 2:
        b += "while ("; gen_ident(b); b += ' '; b += CMPS[(r >> 8) % 6]; b += ' '; gen_int(b);
        b += " && "; gen_ident(b); b += " != "; gen_int(b); b += " || !"; gen_ident(b);
        b += ") {\n    "; gen_ident(b); b += " += "; gen_int(b); b += ";\n}\n";
        break;
    case 3:
        b += "return "; gen_string(b); b += ";\n";
        break;
    case 4:
        b += "//"; gen_words(b); b += '\n';
        break;
    case 5:
        b += "/*"; gen_words(b); b += " */\n";
        break;
    case 6:
        gen_ident(b); b += '('; gen_expr(b); b += ", "; gen_expr(b); b += ");\n";
        break;
    default:
        b += "fn "; gen_ident(b); b += '('; gen_ident(b); b += ", "; gen_ident(b); b += ") -> ";
        gen_ident(b); b += " {\n    let "; gen_ident(b); b += " = "; gen_float(b); b += " * ";
        gen_ident(b); b += " - "; gen_int(b); b += ";\n}\n";
    }
}

int main(int argc, char **argv) {
    size_t n = argc > 1 ? size_t(std::atol(argv[1])) : size_t(32) << 20;
    std::string src;
    while (src.size() < n) gen_statement(src);
    std::array<size_t, KIND_NAMES.size()> counts{};
    size_t total = 0;
    uint64_t check = 0;
    for (int pass = 0; pass < 10; pass++) {
        Lexer lx(src);
        for (Token t = lx.next(); t.kind != Kind::Eof; t = lx.next()) {
            counts[size_t(t.kind)]++;
            total++;
            if (t.kind == Kind::Ident) check = check * 31 + t.text.size();
        }
    }
    std::printf("%zu bytes, %zu tokens\n", src.size(), total);
    for (size_t k = 0; k < counts.size(); k++) std::printf("%s %zu\n", KIND_NAMES[k], counts[k]);
    std::printf("identifier checksum %llu\n", (unsigned long long)check);
}
