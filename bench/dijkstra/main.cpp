// dijkstra: shortest paths over an n x n grid whose edges have random weights, from two corners,
// with a binary heap of (distance, node) and lazy deletion; C++ uses std::vector and
// std::priority_queue of pairs with std::greater
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <functional>
#include <limits>
#include <queue>
#include <utility>
#include <vector>

static uint64_t seed = 88172645463325252ULL;
static uint64_t next() {
    seed ^= seed << 13;
    seed ^= seed >> 7;
    seed ^= seed << 17;
    return seed;
}

using item = std::pair<uint64_t, uint32_t>;

static std::vector<uint64_t> shortest(size_t n, const std::vector<uint32_t> &weight, uint32_t src, uint64_t &relaxed) {
    std::vector<uint64_t> dist(n * n, std::numeric_limits<uint64_t>::max());
    std::priority_queue<item, std::vector<item>, std::greater<item>> heap;
    dist[src] = 0;
    heap.push({0, src});
    while (!heap.empty()) {
        auto [d0, node] = heap.top();
        heap.pop();
        if (d0 > dist[node]) continue;
        size_t x = node % n, y = node / n;
        for (int d = 0; d < 4; d++) {
            size_t nx = x, ny = y;
            if (d == 0) { if (x + 1 >= n) continue; nx = x + 1; }
            else if (d == 1) { if (x == 0) continue; nx = x - 1; }
            else if (d == 2) { if (y + 1 >= n) continue; ny = y + 1; }
            else { if (y == 0) continue; ny = y - 1; }
            uint32_t to = uint32_t(ny * n + nx);
            uint64_t nd = d0 + weight[size_t(node) * 4 + d];
            if (nd < dist[to]) {
                dist[to] = nd;
                relaxed++;
                heap.push({nd, to});
            }
        }
    }
    return dist;
}

int main(int argc, char **argv) {
    size_t n = argc > 1 ? std::strtoul(argv[1], nullptr, 10) : 1500;
    size_t count = n * n;
    std::vector<uint32_t> weight(count * 4);
    for (auto &w : weight) w = uint32_t(next() % 100) + 1;
    uint64_t relaxed = 0;
    uint32_t sources[2] = {0, uint32_t(count - 1)};
    for (int s = 0; s < 2; s++) {
        auto dist = shortest(n, weight, sources[s], relaxed);
        uint64_t sum = 0, far = 0;
        for (auto d : dist) {
            sum += d;
            if (d > far) far = d;
        }
        std::printf("from %u: corner %llu, farthest %llu, sum %llu\n", sources[s], (unsigned long long)dist[sources[1 - s]], (unsigned long long)far, (unsigned long long)sum);
    }
    std::printf("relaxed %llu\n", (unsigned long long)relaxed);
}
