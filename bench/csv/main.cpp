// csv: format n records (an int, a float with two decimals, a quoted string holding a comma) as CSV
// text, then parse them back field by field and sum them; C++ formats with std::format_to into a
// std::string and parses with std::from_chars, throwing on a bad line
#include <charconv>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <format>
#include <iterator>
#include <stdexcept>
#include <string>
#include <string_view>

static uint64_t x = 88172645463325252ULL;

static uint64_t next() {
    x ^= x << 13;
    x ^= x >> 7;
    x ^= x << 17;
    return x;
}

static constexpr std::string_view NAMES[8] = {"alpha", "bravo", "charlie", "delta", "echo", "foxtrot", "golf", "hotel"};

struct record {
    long long id;
    double price;
    std::string_view name;
};

// the record at the front of text, which moves past its newline
static record parse_record(std::string_view &text) {
    record r;
    const char *p = text.data(), *end = text.data() + text.size();
    auto [q, ec] = std::from_chars(p, end, r.id);
    if (ec != std::errc() || q == end || *q != ',') throw std::runtime_error("bad id");
    auto [f, ec2] = std::from_chars(q + 1, end, r.price);
    if (ec2 != std::errc() || end - f < 2 || f[0] != ',' || f[1] != '"') throw std::runtime_error("bad price");
    std::string_view rest(f + 2, end - f - 2);
    size_t close = rest.find('"');
    if (close == rest.npos || close + 1 >= rest.size() || rest[close + 1] != '\n') throw std::runtime_error("bad name");
    r.name = rest.substr(0, close);
    text = rest.substr(close + 2);
    return r;
}

int main(int argc, char **argv) {
    long n = argc > 1 ? std::atol(argv[1]) : 3000000;
    std::string text;
    for (long i = 0; i < n; i++) {
        long long id = (long long)(next() % 2000000001) - 1000000000;
        double price = (double)(next() % 10000000) / 100.0;
        auto a = NAMES[next() % 8];
        auto b = NAMES[next() % 8];
        std::format_to(std::back_inserter(text), "{},{:.2f},\"{}, {}\"\n", id, price, a, b);
    }
    long long ids = 0, cents = 0;
    long records = 0;
    size_t name_bytes = 0;
    std::string_view rest = text;
    while (!rest.empty()) {
        record r = parse_record(rest);
        ids += r.id;
        cents += (long long)(r.price * 100.0 + 0.5);
        name_bytes += r.name.size();
        records++;
    }
    std::printf("%zu bytes, %ld records\n%lld %lld %zu\n", text.size(), records, ids, cents, name_bytes);
}
