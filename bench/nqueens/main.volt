// nqueens: counts the placements of n queens on an n x n board with bitboards and recursion; Volt
// keeps the board's three attack masks in a struct with methods, passed by value
use std::io;
use std::text;

struct board {
    cols: u32;
    left: u32;
    right: u32;
}

attach fn place(this: board, bit: u32) -> board {
    return { cols: this.cols | bit, left: (this.left | bit) << 1, right: (this.right | bit) >> 1 };
}

attach fn free(this: board, all: u32) -> u32 {
    return all & ~(this.cols | this.left | this.right);
}

fn solve(all: u32, b: board) -> u64 {
    if (b.cols == all) {
        return 1;
    }
    var count: u64 = 0;
    var free = b.free(all);
    while (free != 0) {
        val bit = free & (~free +% 1);
        free ^= bit;
        count += solve(all, b.place(bit));
    }
    return count;
}

fn main() -> void {
    val n = (std::process::arg(1) ?? "15").parse_int() catch 15;
    val all = (@cast<u32>(1) << @cast<u32>(n)) - 1;
    std::println("{} queens: {}", n, solve(all, { cols: 0, left: 0, right: 0 }));
}
