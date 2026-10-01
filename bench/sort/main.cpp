// sort: n pseudo-random 64-bit integers with std::stable_sort (Volt's sort is stable too)
#include <algorithm>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <vector>

int main(int argc, char **argv) {
    long n = argc > 1 ? std::atol(argv[1]) : 5000000;
    std::vector<int64_t> xs(n);
    uint64_t s = 7;
    for (auto &x : xs) { s = s * 6364136223846793005ull + 1442695040888963407ull; x = (int64_t)(s >> 1) % 1000000007; }
    std::stable_sort(xs.begin(), xs.end());
    uint64_t check = 0;
    for (auto x : xs) check = check * 31 + (uint64_t)x;
    std::printf("%lld %lld %llu\n", (long long)xs.front(), (long long)xs.back(), (unsigned long long)check);
}
