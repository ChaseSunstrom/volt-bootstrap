// vec_grow: growing arrays one push at a time (no reserve), then summing them, many times over
#include <cstdio>
#include <cstdlib>
#include <vector>

int main(int argc, char **argv) {
    long n = argc > 1 ? std::atol(argv[1]) : 20000000;
    unsigned long total = 0;
    for (int round = 0; round < 10; round++) {
        std::vector<long> xs;
        for (long i = 0; i < n; i++) xs.push_back(i * 3 + round);
        for (long x : xs) total += (unsigned long)x;
    }
    std::printf("%lu\n", total);
}
