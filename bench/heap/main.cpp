// heap: a binary min-heap used for two element types: n random integers, then n tasks ordered by
// (priority, id), each pushed then popped in order; C++ uses std::priority_queue, a template, with
// std::greater for the integers and the task's operator> for the tasks
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <functional>
#include <queue>
#include <vector>

static uint64_t seed = 88172645463325252ULL;
static uint64_t next() {
    seed ^= seed << 13;
    seed ^= seed >> 7;
    seed ^= seed << 17;
    return seed;
}

struct task {
    uint32_t priority, id;
    bool operator>(const task &o) const { return priority > o.priority || (priority == o.priority && id > o.id); }
};

int main(int argc, char **argv) {
    size_t n = argc > 1 ? std::strtoul(argv[1], nullptr, 10) : 3000000;
    std::priority_queue<uint64_t, std::vector<uint64_t>, std::greater<uint64_t>> ints;
    for (size_t i = 0; i < n; i++) ints.push(next() >> 16);
    uint64_t sum = 0, prev = 0, sorted = 1;
    for (size_t i = 0; i < n; i++) {
        uint64_t v = ints.top();
        ints.pop();
        sorted &= prev <= v;
        prev = v;
        sum = sum * 31 + v;
    }
    std::priority_queue<task, std::vector<task>, std::greater<task>> tasks;
    for (size_t i = 0; i < n; i++) tasks.push({(uint32_t)(next() % 1000), (uint32_t)i});
    uint64_t order = 0;
    for (size_t i = 0; i < n; i++) {
        order = order * 31 + tasks.top().id;
        tasks.pop();
    }
    std::printf("%llu %llu %llu\n", (unsigned long long)sorted, (unsigned long long)sum, (unsigned long long)order);
}
