// sudoku: backtracking over hard sudoku puzzles, each solved with its digits relabelled at random in
// every round so the search differs: a bit mask of the digits used per row, column and box, and the
// empty cell with the fewest candidates tried next; the search goes on past the first solution to
// show it's the only one. Prints the puzzles solved, the guesses made and a checksum of the solutions
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>

static const char *PUZZLES[] = {
    "4.....8.5.3..........7......2.....6.....8.4......1.......6.3.7.5..2.....1.4......",
    "52...6.........7.13...........4..8..6......5...........418.........3..2...87.....",
    "6.....8.3.4.7.................5.4.7.3..2.....1.6.......2.....5.....8.6......1....",
    "48.3............71.2.......7.5....6....2..8.............1.76...3.....4......5....",
    "....14....3....2...7..........9...3.6.1.............8.2.....1.4....5.6.....7.8...",
    "8..........36......7..9.2...5...7.......457.....1...3...1....68..85...1..9....4..",
    "..53.....8......2..7..1.5..4....53...1..7...6..32...8..6.5....9..4....3......97..",
    "..............3.85..1.2.......5.7.....4...1...9.......5......73..2.1........4...9",
    "1....7.9..3..2...8..96..5....53..9...1..8...26....4...3......1..4......7..7...3..",
    ".2.4.37.........32........4.4.2...7.8...5.........1...5.....9...3.9....7..1..86..",
    "..3......4...8..36..8...1...4..6..73...9..........2..5..4.7..686........7..6..5..",
    "12.3....435....1....4........54..2..6...7.........8.9...31..5.......9.7.....6...8",
    ".......1.4.........2...........5.4.7..8...3....1.9....3..4..2...5.1........8.6...",
};
#define NPUZZLES (sizeof PUZZLES / sizeof PUZZLES[0])

static uint8_t BITS[512]; // the number of bits set in each 9-bit mask

typedef struct {
    uint8_t cell[81]; // 0 for empty, else 1 to 9
    uint16_t row[9], col[9], box[9]; // bit d - 1: digit d is used
    uint8_t first[81]; // the first solution found
    int solutions;
    uint64_t guesses;
} board;

static int box_of(int i) { return i / 27 * 3 + i % 9 / 3; }

static void set(board *b, int i, int d) {
    uint16_t bit = (uint16_t)(1 << (d - 1));
    b->cell[i] = (uint8_t)d;
    b->row[i / 9] |= bit;
    b->col[i % 9] |= bit;
    b->box[box_of(i)] |= bit;
}

static void unset(board *b, int i, int d) {
    uint16_t bit = (uint16_t)~(1 << (d - 1));
    b->cell[i] = 0;
    b->row[i / 9] &= bit;
    b->col[i % 9] &= bit;
    b->box[box_of(i)] &= bit;
}

static void search(board *b) {
    int best = -1, fewest = 10;
    uint16_t options = 0;
    for (int i = 0; i < 81; i++) {
        if (b->cell[i]) continue;
        uint16_t avail = ~(b->row[i / 9] | b->col[i % 9] | b->box[box_of(i)]) & 0x1FF;
        if (BITS[avail] < fewest) {
            best = i;
            fewest = BITS[avail];
            options = avail;
            if (fewest <= 1) break;
        }
    }
    if (best < 0) {
        if (b->solutions++ == 0)
            for (int i = 0; i < 81; i++) b->first[i] = b->cell[i];
        return;
    }
    for (int d = 1; d <= 9 && b->solutions < 2; d++) {
        if (!(options & (1 << (d - 1)))) continue;
        b->guesses++;
        set(b, best, d);
        search(b);
        unset(b, best, d);
    }
}

static uint64_t x = 88172645463325252ULL;

static uint64_t next(void) {
    x ^= x << 13;
    x ^= x >> 7;
    x ^= x << 17;
    return x;
}

int main(int argc, char **argv) {
    int rounds = argc > 1 ? atoi(argv[1]) : 25;
    for (int m = 0; m < 512; m++) BITS[m] = (uint8_t)((m & 1) + BITS[m >> 1]);
    int solved = 0, unique = 0;
    uint64_t guesses = 0, check = 14695981039346656037ULL;
    for (int r = 0; r < rounds; r++) {
        for (size_t p = 0; p < NPUZZLES; p++) {
            // a random relabelling of the digits
            int perm[10];
            for (int d = 0; d <= 9; d++) perm[d] = d;
            for (int d = 9; d > 1; d--) {
                int k = 1 + (int)(next() % (uint64_t)d);
                int t = perm[d];
                perm[d] = perm[k];
                perm[k] = t;
            }
            board b = { 0 };
            for (int i = 0; i < 81; i++)
                if (PUZZLES[p][i] != '.') set(&b, i, perm[PUZZLES[p][i] - '0']);
            search(&b);
            guesses += b.guesses;
            if (b.solutions > 0) solved++;
            if (b.solutions == 1) unique++;
            for (int i = 0; i < 81; i++) check = (check ^ b.first[i]) * 1099511628211ULL;
        }
    }
    printf("%d puzzles solved, %d with one solution\n", solved, unique);
    printf("%llu guesses, checksum %llu\n", (unsigned long long)guesses, (unsigned long long)check);
    return 0;
}
