// nqueens: counts the placements of n queens on an n x n board with bitboards and recursion; C++
// keeps the board's three attack masks in a small struct passed by value
#include <cstdint>
#include <cstdio>
#include <cstdlib>

struct board {
    uint32_t cols, left, right;
    board place(uint32_t bit) const { return {cols | bit, (left | bit) << 1, (right | bit) >> 1}; }
    uint32_t free(uint32_t all) const { return all & ~(cols | left | right); }
};

static uint64_t solve(uint32_t all, board b) {
    if (b.cols == all) return 1;
    uint64_t count = 0;
    for (uint32_t free = b.free(all); free; free &= free - 1) {
        uint32_t bit = free & -free;
        count += solve(all, b.place(bit));
    }
    return count;
}

int main(int argc, char **argv) {
    int n = argc > 1 ? std::atoi(argv[1]) : 15;
    uint32_t all = (1u << n) - 1;
    std::printf("%d queens: %llu\n", n, (unsigned long long)solve(all, {0, 0, 0}));
}
