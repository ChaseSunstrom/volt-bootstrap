// life: Conway's game of life on an n x n grid that wraps at the edges (a torus), a byte per cell,
// from a random start for 400 generations; prints the population every 100 generations and a
// checksum of the last grid. C++ keeps each grid in a std::vector
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <numeric>
#include <utility>
#include <vector>

static uint64_t x = 88172645463325252ULL;

static uint64_t next() {
    x ^= x << 13;
    x ^= x >> 7;
    x ^= x << 17;
    return x;
}

static void step(const std::vector<uint8_t> &cur, std::vector<uint8_t> &out, size_t n) {
    for (size_t y = 0; y < n; y++) {
        const uint8_t *up = &cur[(y == 0 ? n - 1 : y - 1) * n], *row = &cur[y * n], *down = &cur[(y == n - 1 ? 0 : y + 1) * n];
        for (size_t x = 0; x < n; x++) {
            size_t l = x == 0 ? n - 1 : x - 1, r = x == n - 1 ? 0 : x + 1;
            int around = up[l] + up[x] + up[r] + row[l] + row[r] + down[l] + down[x] + down[r];
            out[y * n + x] = around == 3 || (around == 2 && row[x]);
        }
    }
}

int main(int argc, char **argv) {
    size_t n = argc > 1 ? std::strtoull(argv[1], nullptr, 10) : 1024;
    std::vector<uint8_t> a(n * n), b(n * n);
    for (auto &c : a) c = next() % 3 == 0;
    for (int gen = 0; gen <= 400; gen++) {
        if (gen % 100 == 0) std::printf("generation %d: %zu alive\n", gen, std::accumulate(a.begin(), a.end(), size_t(0)));
        if (gen == 400) break;
        step(a, b, n);
        std::swap(a, b);
    }
    uint64_t check = 14695981039346656037ULL;
    for (uint8_t c : a) check = (check ^ c) * 1099511628211ULL;
    std::printf("checksum %llu\n", (unsigned long long)check);
}
