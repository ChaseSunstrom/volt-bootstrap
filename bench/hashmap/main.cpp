// hash map churn: insert n pseudo-random keys, look each up plus as many misses, remove half
// (std::unordered_map)
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <unordered_map>

int main(int argc, char **argv) {
    long n = argc > 1 ? std::atol(argv[1]) : 5000000;
    std::unordered_map<uint64_t, uint64_t> m;
    uint64_t x = 42, sum = 0, found = 0;
    for (long i = 0; i < n; i++) { x = x * 6364136223846793005ull + 1442695040888963407ull; m[x >> 16] = i; }
    x = 42;
    for (long i = 0; i < n; i++) {
        x = x * 6364136223846793005ull + 1442695040888963407ull;
        auto it = m.find(x >> 16);
        if (it != m.end()) { sum += it->second; found++; }
        if (m.count((x >> 16) + 1)) found++;
    }
    x = 42;
    long removed = 0;
    for (long i = 0; i < n; i += 2) {
        x = x * 6364136223846793005ull + 1442695040888963407ull;
        removed += m.erase(x >> 16);
        x = x * 6364136223846793005ull + 1442695040888963407ull;
    }
    std::printf("%zu %llu %llu %ld\n", m.size(), (unsigned long long)found, (unsigned long long)sum, removed);
}
