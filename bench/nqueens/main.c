// nqueens: counts the placements of n queens on an n x n board with bitboards and recursion: the
// columns and both diagonals under attack are bit masks, the free squares a mask that's peeled a bit
// at a time
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>

static uint64_t solve(uint32_t all, uint32_t cols, uint32_t left, uint32_t right) {
    if (cols == all) return 1;
    uint64_t count = 0;
    uint32_t free = all & ~(cols | left | right);
    while (free) {
        uint32_t bit = free & -free;
        free ^= bit;
        count += solve(all, cols | bit, (left | bit) << 1, (right | bit) >> 1);
    }
    return count;
}

int main(int argc, char **argv) {
    int n = argc > 1 ? atoi(argv[1]) : 15;
    uint32_t all = (1u << n) - 1;
    printf("%d queens: %llu\n", n, (unsigned long long)solve(all, 0, 0, 0));
    return 0;
}
