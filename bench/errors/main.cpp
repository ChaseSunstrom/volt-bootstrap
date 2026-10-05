// errors: lines of comma-separated numbers, about 1 in 100 malformed, parsed through three layers of
// calls (parse_list -> parse_number -> parse_digits), many rounds; the caller counts the lines that
// fail and sums the rest. C++ throws an exception and catches it in the caller
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <exception>
#include <string>
#include <string_view>

struct parse_error : std::exception {
    enum kind { empty, bad_digit } what_went_wrong;
    explicit parse_error(kind k) : what_went_wrong(k) {}
    const char *what() const noexcept override { return what_went_wrong == empty ? "empty" : "bad digit"; }
};

class parser {
    std::string_view text;
    size_t pos = 0;

    // the digits up to the next ',' or '\n'
    int64_t parse_digits() {
        size_t start = pos;
        int64_t v = 0;
        while (pos < text.size()) {
            char c = text[pos];
            if (c == ',' || c == '\n') break;
            if (c < '0' || c > '9') throw parse_error(parse_error::bad_digit);
            v = v * 10 + (c - '0');
            pos++;
        }
        if (pos == start) throw parse_error(parse_error::empty);
        return v;
    }

    int64_t parse_number() {
        if (pos < text.size() && text[pos] == '-') {
            pos++;
            return -parse_digits();
        }
        return parse_digits();
    }

public:
    explicit parser(std::string_view text) : text(text) {}
    bool done() const { return pos >= text.size(); }

    // one line's numbers: their sum
    int64_t parse_list() {
        int64_t sum = 0;
        for (;;) {
            sum += parse_number();
            if (pos >= text.size() || text[pos] == '\n') break;
            pos++;
        }
        pos++;
        return sum;
    }

    void skip_line() {
        while (pos < text.size() && text[pos] != '\n') pos++;
        pos++;
    }
};

static uint64_t rng = 88172645463325252ULL;
static uint64_t next() {
    rng ^= rng << 13;
    rng ^= rng >> 7;
    rng ^= rng << 17;
    return rng;
}

int main(int argc, char **argv) {
    long rounds = argc > 1 ? std::atol(argv[1]) : 1000;
    size_t lines = 20000;
    std::string text;
    for (size_t i = 0; i < lines; i++) {
        uint64_t count = 1 + next() % 10;
        for (uint64_t k = 0; k < count; k++) {
            if (k > 0) text += ',';
            uint64_t r = next() % 200;
            if (r == 0) continue; // an empty field
            if (r % 4 == 2) text += '-';
            text += std::to_string(next() % 1000000);
            if (r == 1) text += 'x'; // a stray letter
        }
        text += '\n';
    }
    int64_t total = 0;
    long failures = 0;
    for (long round = 0; round < rounds; round++) {
        parser p(text);
        while (!p.done()) {
            try {
                total += p.parse_list();
            } catch (const parse_error &) {
                failures++;
                p.skip_line();
            }
        }
    }
    std::printf("%zu bytes, %lld total, %ld failures\n", text.size(), (long long)total, failures);
}
