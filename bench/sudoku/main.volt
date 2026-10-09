// sudoku: backtracking over hard sudoku puzzles, each solved with its digits relabelled at random in
// every round so the search differs: a bit mask of the digits used per row, column and box, and the
// empty cell with the fewest candidates tried next; the search goes on past the first solution to
// show it's the only one. Prints the puzzles solved, the guesses made and a checksum of the
// solutions. Volt builds the bit-count table at compile time and keeps the board in a struct with
// methods, the cell to try next and the first solution in optionals
use std::io;
use std::text;

val PUZZLES: str[13] = {
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
comptime fn bit_counts() -> u8[512] {
    var bits: u8[512] = {};
    for (m) in 1..512 {
        bits[m] = @cast<u8>(m & 1) + bits[m >> 1];
    }
    return bits;
}

val BITS = bit_counts();

fn box_of(i: usize) -> usize {
    return i / 27 * 3 + i % 9 / 3;
}

struct board {
    cell: u8[81] = {}; // 0 for empty, else 1 to 9
    row: u16[9] = {}; // bit d - 1: digit d is used
    col: u16[9] = {};
    box: u16[9] = {};
    first: u8[81]? = null; // the first solution found
    solutions: u32 = 0;
    guesses: u64 = 0;
}

attach fn set(this: board&, i: usize, d: u8) -> void {
    val bit = @cast<u16>(1) << @cast<u16>(d - 1);
    this.cell[i] = d;
    this.row[i / 9] |= bit;
    this.col[i % 9] |= bit;
    this.box[box_of(i)] |= bit;
}

attach fn unset(this: board&, i: usize, d: u8) -> void {
    val bit = ~(@cast<u16>(1) << @cast<u16>(d - 1));
    this.cell[i] = 0;
    this.row[i / 9] &= bit;
    this.col[i % 9] &= bit;
    this.box[box_of(i)] &= bit;
}

attach fn search(this: board&) -> void {
    var best: usize? = null;
    var fewest: u8 = 10;
    var options: u16 = 0;
    for (i) in @cast<usize>(0)..81 {
        if (this.cell[i] != 0) {
            continue;
        }
        val free = ~(this.row[i / 9] | this.col[i % 9] | this.box[box_of(i)]) & 0x1FF;
        if (BITS[free] < fewest) {
            best = i;
            fewest = BITS[free];
            options = free;
            if (fewest <= 1) {
                break;
            }
        }
    }
    if (best == null) {
        if (this.first == null) {
            this.first = this.cell;
        }
        this.solutions += 1;
        return;
    }
    val at = best ?? return;
    for (d) in @cast<u8>(1)..=9 {
        if (this.solutions >= 2) {
            break;
        }
        if ((options & (@cast<u16>(1) << @cast<u16>(d - 1))) == 0) {
            continue;
        }
        this.guesses += 1;
        this.set(at, d);
        this.search();
        this.unset(at, d);
    }
}

var x: u64 = 88172645463325252;

fn next() -> u64 {
    x = x ^ (x << 13);
    x = x ^ (x >> 7);
    x = x ^ (x << 17);
    return x;
}

fn main() -> void {
    val rounds = @cast<usize>((std::process::arg(1) ?? "25").parse_int() catch 25);
    var solved = 0;
    var unique = 0;
    var guesses: u64 = 0;
    var check: u64 = 14695981039346656037;
    for (r) in 0..rounds {
        for (puzzle) in PUZZLES {
            // a random relabelling of the digits
            var perm: u8[10] = { 0, 1, 2, 3, 4, 5, 6, 7, 8, 9 };
            var d: usize = 9;
            while (d > 1) {
                perm[..].swap(d, 1 + @cast<usize>(next() % @cast<u64>(d)));
                d -= 1;
            }
            var b: board = {};
            for (c, i) in puzzle {
                if (c != '.') {
                    b.set(i, perm[c - '0']);
                }
            }
            b.search();
            guesses += b.guesses;
            if (b.solutions > 0) {
                solved += 1;
            }
            if (b.solutions == 1) {
                unique += 1;
            }
            val first: u8[81] = b.first ?? {};
            for (c) in first {
                check = (check ^ @cast<u64>(c)) *% 1099511628211;
            }
        }
    }
    std::println("{} puzzles solved, {} with one solution", solved, unique);
    std::println("{} guesses, checksum {}", guesses, check);
}
