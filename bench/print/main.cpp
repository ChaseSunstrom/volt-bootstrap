// print: half a million doubles in [1, 2) as the shortest text that reads back as the same value
// (std::to_chars), then half a million integers, a line each
#include <charconv>
#include <cstdint>
#include <cstdio>
#include <cstdlib>

static uint64_t x = 88172645463325252ULL;

static uint64_t next() {
    x ^= x << 13;
    x ^= x >> 7;
    x ^= x << 17;
    return x;
}

int main(int argc, char **argv) {
    long n = argc > 1 ? std::atol(argv[1]) : 500000;
    char buf[32];
    for (long i = 0; i < n; i++) {
        double v = 1.0 + (double)(next() >> 12) / 4503599627370496.0;
        auto r = std::to_chars(buf, buf + sizeof buf, v);
        std::printf("%.*s\n", (int)(r.ptr - buf), buf);
    }
    for (long i = 0; i < n; i++) std::printf("%lld\n", (long long)(next() >> 1));
}
