// nqueens: counts the placements of n queens on an n x n board with bitboards and recursion: the
// columns and both diagonals under attack are bit masks, the free squares a mask that's peeled a bit
// at a time
fn solve(all: u32, cols: u32, left: u32, right: u32) -> u64 {
    if cols == all {
        return 1;
    }
    let mut count = 0;
    let mut free = all & !(cols | left | right);
    while free != 0 {
        let bit = free & free.wrapping_neg();
        free ^= bit;
        count += solve(all, cols | bit, (left | bit) << 1, (right | bit) >> 1);
    }
    count
}

fn main() {
    let n: u32 = std::env::args().nth(1).and_then(|a| a.parse().ok()).unwrap_or(15);
    let all = (1u32 << n) - 1;
    println!("{n} queens: {}", solve(all, 0, 0, 0));
}
