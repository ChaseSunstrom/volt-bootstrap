// closures: a map / filter / fold pipeline over an array, many rounds; C++ passes lambdas to a template
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <vector>

template <class F, class K> int64_t pipeline(const std::vector<int64_t> &xs, F f, K keep) {
    int64_t sum = 0;
    for (auto x : xs) { int64_t y = f(x); if (keep(y)) sum += y; }
    return sum;
}

int main(int argc, char **argv) {
    long rounds = argc > 1 ? std::atol(argv[1]) : 1000;
    std::vector<int64_t> xs(1000000);
    for (size_t i = 0; i < xs.size(); i++) xs[i] = i % 1000;
    int64_t total = 0;
    for (long r = 0; r < rounds; r++) {
        int64_t factor = r % 7 + 2, limit = 5000 - r;
        total += pipeline(xs, [factor](int64_t x) { return x * factor + 1; }, [limit](int64_t y) { return y % 3 != 0 && y < limit; });
    }
    std::printf("%lld\n", (long long)total);
}
