// lru_cache: an LRU cache of 100000 int keys to owned strings under n skewed get/put operations
// (a miss puts the value); C++ uses a class over std::list (recency) and std::unordered_map from
// key to list iterator, with std::string values
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <list>
#include <string>
#include <string_view>
#include <unordered_map>
#include <utility>

static uint64_t x = 88172645463325252ULL;

static uint64_t next() {
    x ^= x << 13;
    x ^= x >> 7;
    x ^= x << 17;
    return x;
}

class lru_cache {
    size_t cap;
    std::list<std::pair<uint64_t, std::string>> order; // front is the most recent
    std::unordered_map<uint64_t, decltype(order)::iterator> index;

public:
    explicit lru_cache(size_t cap) : cap(cap) { index.reserve(cap); }
    size_t size() const { return index.size(); }

    // the value for key (marked most recent), or nullptr
    const std::string *get(uint64_t key) {
        auto it = index.find(key);
        if (it == index.end()) return nullptr;
        order.splice(order.begin(), order, it->second);
        return &it->second->second;
    }

    // set key to value, evicting the least recent key when full
    void put(uint64_t key, std::string value) {
        auto it = index.find(key);
        if (it != index.end()) {
            it->second->second = std::move(value);
            order.splice(order.begin(), order, it->second);
            return;
        }
        if (index.size() == cap) {
            index.erase(order.back().first);
            order.pop_back();
        }
        order.emplace_front(key, std::move(value));
        index.emplace(key, order.begin());
    }
};

static constexpr std::string_view PATTERN = "abcdefghijklmnopqrstuvwxyzabcdefghijklmnopqrstuvwxyzabcdefghijklmnop";

// the value stored for key at step i: 8 to 32 letters
static std::string make_value(uint64_t key, long i) { return std::string(PATTERN.substr(key % 26, 8 + (key + i) % 25)); }

int main(int argc, char **argv) {
    long n = argc > 1 ? std::atol(argv[1]) : 20000000;
    lru_cache cache(100000);
    long hits = 0, misses = 0, total = 0;
    for (long i = 0; i < n; i++) {
        uint64_t r = next();
        // three in four keys come from a hot set a little bigger than the cache
        uint64_t key = r % 4 ? next() % 120000 : next() % 1000000;
        if ((r >> 8) % 10 == 0) {
            cache.put(key, make_value(key, i));
            continue;
        }
        if (auto v = cache.get(key)) {
            hits++;
            total += v->size();
        } else {
            misses++;
            cache.put(key, make_value(key, i));
        }
    }
    std::printf("%ld hits, %ld misses, %ld total, %zu cached\n", hits, misses, total, cache.size());
}
