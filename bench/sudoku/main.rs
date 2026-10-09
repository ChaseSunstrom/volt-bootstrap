// sudoku: backtracking over hard sudoku puzzles, each solved with its digits relabelled at random in
// every round so the search differs: a bit mask of the digits used per row, column and box, and the
// empty cell with the fewest candidates tried next; the search goes on past the first solution to
// show it's the only one. Prints the puzzles solved, the guesses made and a checksum of the solutions
const PUZZLES: [&[u8; 81]; 13] = [
    b"4.....8.5.3..........7......2.....6.....8.4......1.......6.3.7.5..2.....1.4......",
    b"52...6.........7.13...........4..8..6......5...........418.........3..2...87.....",
    b"6.....8.3.4.7.................5.4.7.3..2.....1.6.......2.....5.....8.6......1....",
    b"48.3............71.2.......7.5....6....2..8.............1.76...3.....4......5....",
    b"....14....3....2...7..........9...3.6.1.............8.2.....1.4....5.6.....7.8...",
    b"8..........36......7..9.2...5...7.......457.....1...3...1....68..85...1..9....4..",
    b"..53.....8......2..7..1.5..4....53...1..7...6..32...8..6.5....9..4....3......97..",
    b"..............3.85..1.2.......5.7.....4...1...9.......5......73..2.1........4...9",
    b"1....7.9..3..2...8..96..5....53..9...1..8...26....4...3......1..4......7..7...3..",
    b".2.4.37.........32........4.4.2...7.8...5.........1...5.....9...3.9....7..1..86..",
    b"..3......4...8..36..8...1...4..6..73...9..........2..5..4.7..686........7..6..5..",
    b"12.3....435....1....4........54..2..6...7.........8.9...31..5.......9.7.....6...8",
    b".......1.4.........2...........5.4.7..8...3....1.9....3..4..2...5.1........8.6...",
];

// the number of bits set in each 9-bit mask
const BITS: [u8; 512] = {
    let mut bits = [0u8; 512];
    let mut m = 1;
    while m < 512 {
        bits[m] = (m & 1) as u8 + bits[m >> 1];
        m += 1;
    }
    bits
};

struct Board {
    cell: [u8; 81], // 0 for empty, else 1 to 9
    row: [u16; 9], // bit d - 1: digit d is used
    col: [u16; 9],
    sq: [u16; 9],
    first: Option<[u8; 81]>, // the first solution found
    solutions: u32,
    guesses: u64,
}

fn box_of(i: usize) -> usize {
    i / 27 * 3 + i % 9 / 3
}

impl Board {
    fn set(&mut self, i: usize, d: u8) {
        let bit = 1u16 << (d - 1);
        self.cell[i] = d;
        self.row[i / 9] |= bit;
        self.col[i % 9] |= bit;
        self.sq[box_of(i)] |= bit;
    }

    fn unset(&mut self, i: usize, d: u8) {
        let bit = !(1u16 << (d - 1));
        self.cell[i] = 0;
        self.row[i / 9] &= bit;
        self.col[i % 9] &= bit;
        self.sq[box_of(i)] &= bit;
    }

    fn search(&mut self) {
        let mut best = None;
        let mut fewest = 10;
        let mut options = 0u16;
        for i in 0..81 {
            if self.cell[i] != 0 {
                continue;
            }
            let free = !(self.row[i / 9] | self.col[i % 9] | self.sq[box_of(i)]) & 0x1FF;
            if BITS[free as usize] < fewest {
                best = Some(i);
                fewest = BITS[free as usize];
                options = free;
                if fewest <= 1 {
                    break;
                }
            }
        }
        let Some(best) = best else {
            self.solutions += 1;
            if self.first.is_none() {
                self.first = Some(self.cell);
            }
            return;
        };
        for d in 1..=9u8 {
            if self.solutions >= 2 {
                break;
            }
            if options & (1 << (d - 1)) == 0 {
                continue;
            }
            self.guesses += 1;
            self.set(best, d);
            self.search();
            self.unset(best, d);
        }
    }
}

struct Rng(u64);

impl Rng {
    fn next(&mut self) -> u64 {
        self.0 ^= self.0 << 13;
        self.0 ^= self.0 >> 7;
        self.0 ^= self.0 << 17;
        self.0
    }
}

fn main() {
    let rounds: u32 = std::env::args().nth(1).and_then(|a| a.parse().ok()).unwrap_or(25);
    let mut rng = Rng(88172645463325252);
    let (mut solved, mut unique, mut guesses) = (0, 0, 0u64);
    let mut check = 14695981039346656037u64;
    for _ in 0..rounds {
        for puzzle in PUZZLES {
            // a random relabelling of the digits
            let mut perm: [u8; 10] = [0, 1, 2, 3, 4, 5, 6, 7, 8, 9];
            for d in (2..=9).rev() {
                perm.swap(d, 1 + (rng.next() % d as u64) as usize);
            }
            let mut b = Board { cell: [0; 81], row: [0; 9], col: [0; 9], sq: [0; 9], first: None, solutions: 0, guesses: 0 };
            for (i, &c) in puzzle.iter().enumerate() {
                if c != b'.' {
                    b.set(i, perm[(c - b'0') as usize]);
                }
            }
            b.search();
            guesses += b.guesses;
            if b.solutions > 0 {
                solved += 1;
            }
            if b.solutions == 1 {
                unique += 1;
            }
            for &c in &b.first.unwrap_or([0; 81]) {
                check = (check ^ c as u64).wrapping_mul(1099511628211);
            }
        }
    }
    println!("{solved} puzzles solved, {unique} with one solution");
    println!("{guesses} guesses, checksum {check}");
}
