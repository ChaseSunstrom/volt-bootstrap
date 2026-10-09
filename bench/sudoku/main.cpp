// sudoku: backtracking over hard sudoku puzzles, each solved with its digits relabelled at random in
// every round so the search differs: a bit mask of the digits used per row, column and box, and the
// empty cell with the fewest candidates tried next; the search goes on past the first solution to
// show it's the only one. Prints the puzzles solved, the guesses made and a checksum of the solutions
#include <array>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <string_view>
#include <utility>

constexpr std::string_view PUZZLES[] = {
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

// the number of bits set in each 9-bit mask
constexpr auto BITS = [] {
    std::array<uint8_t, 512> bits{};
    for (int m = 1; m < 512; m++) bits[m] = uint8_t((m & 1) + bits[m >> 1]);
    return bits;
}();

struct Board {
    std::array<uint8_t, 81> cell{}; // 0 for empty, else 1 to 9
    std::array<uint16_t, 9> row{}, col{}, box{}; // bit d - 1: digit d is used
    std::array<uint8_t, 81> first{}; // the first solution found
    int solutions = 0;
    uint64_t guesses = 0;

    static int box_of(int i) { return i / 27 * 3 + i % 9 / 3; }

    void set(int i, int d) {
        uint16_t bit = uint16_t(1 << (d - 1));
        cell[i] = uint8_t(d);
        row[i / 9] |= bit;
        col[i % 9] |= bit;
        box[box_of(i)] |= bit;
    }

    void unset(int i, int d) {
        uint16_t bit = uint16_t(~(1 << (d - 1)));
        cell[i] = 0;
        row[i / 9] &= bit;
        col[i % 9] &= bit;
        box[box_of(i)] &= bit;
    }

    void search() {
        int best = -1, fewest = 10;
        uint16_t options = 0;
        for (int i = 0; i < 81; i++) {
            if (cell[i]) continue;
            uint16_t free = ~(row[i / 9] | col[i % 9] | box[box_of(i)]) & 0x1FF;
            if (BITS[free] < fewest) {
                best = i;
                fewest = BITS[free];
                options = free;
                if (fewest <= 1) break;
            }
        }
        if (best < 0) {
            if (solutions++ == 0) first = cell;
            return;
        }
        for (int d = 1; d <= 9 && solutions < 2; d++) {
            if (!(options & (1 << (d - 1)))) continue;
            guesses++;
            set(best, d);
            search();
            unset(best, d);
        }
    }
};

static uint64_t x = 88172645463325252ULL;

static uint64_t next() {
    x ^= x << 13;
    x ^= x >> 7;
    x ^= x << 17;
    return x;
}

int main(int argc, char **argv) {
    int rounds = argc > 1 ? std::atoi(argv[1]) : 25;
    int solved = 0, unique = 0;
    uint64_t guesses = 0, check = 14695981039346656037ULL;
    for (int r = 0; r < rounds; r++) {
        for (std::string_view puzzle : PUZZLES) {
            // a random relabelling of the digits
            std::array<int, 10> perm;
            for (int d = 0; d <= 9; d++) perm[d] = d;
            for (int d = 9; d > 1; d--) std::swap(perm[d], perm[1 + next() % uint64_t(d)]);
            Board b;
            for (int i = 0; i < 81; i++)
                if (puzzle[i] != '.') b.set(i, perm[puzzle[i] - '0']);
            b.search();
            guesses += b.guesses;
            if (b.solutions > 0) solved++;
            if (b.solutions == 1) unique++;
            for (uint8_t c : b.first) check = (check ^ c) * 1099511628211ULL;
        }
    }
    std::printf("%d puzzles solved, %d with one solution\n", solved, unique);
    std::printf("%llu guesses, checksum %llu\n", (unsigned long long)guesses, (unsigned long long)check);
}
