// btree: an ordered map from u64 to u64 under random inserts (some overwriting), lookups (two in five
// of them hits) and range scans of 100 entries from a random key; prints the size, the hits and a
// checksum of what the lookups and scans saw. C++ uses std::map (a red-black tree)
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <map>

static uint64_t x = 88172645463325252ULL;

static uint64_t next() {
    x ^= x << 13;
    x ^= x >> 7;
    x ^= x << 17;
    return x;
}

int main(int argc, char **argv) {
    size_t n = argc > 1 ? std::strtoull(argv[1], nullptr, 10) : 2000000;
    uint64_t space = 2 * n; // keys are drawn from 0..space
    std::map<uint64_t, uint64_t> t;
    for (size_t i = 0; i < n; i++) t.insert_or_assign(next() % space, i);
    size_t hits = 0;
    uint64_t check = 0;
    for (size_t i = 0; i < n; i++) {
        auto it = t.find(next() % space);
        if (it != t.end()) {
            hits++;
            check += it->second;
        }
    }
    for (size_t i = 0; i < n / 10; i++) {
        auto it = t.lower_bound(next() % space);
        for (int k = 0; k < 100 && it != t.end(); k++, ++it) check = check * 31 + it->first + it->second;
    }
    std::printf("%zu entries, %zu of %zu lookups found\n", t.size(), hits, n);
    std::printf("checksum %llu\n", (unsigned long long)check);
}
