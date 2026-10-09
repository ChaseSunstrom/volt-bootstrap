// life: Conway's game of life on an n x n grid that wraps at the edges (a torus), a byte per cell,
// from a random start for 400 generations; prints the population every 100 generations and a
// checksum of the last grid. Volt's grid is a struct over a std::vec with attached methods, read a
// row slice at a time
use std::io;
use std::text;

struct grid {
    n: usize;
    cells: std::vec<u8> = {};
}

attach fn row(this: grid&, y: usize) -> u8[..] {
    return this.cells.items()[y * this.n..(y + 1) * this.n];
}

attach fn population(this: grid&) -> usize {
    var count: usize = 0;
    for (c) in this.cells.items() {
        count += @cast<usize>(c);
    }
    return count;
}

// the next generation of this, into out
attach fn step(this: grid&, out: grid&) -> void {
    val n = this.n;
    for (y) in 0..n {
        val up = this.row(if (y == 0) n - 1 else y - 1);
        val mid = this.row(y);
        val down = this.row(if (y == n - 1) 0 else y + 1);
        val dst = out.row(y);
        for (i) in 0..n {
            val l: usize = if (i == 0) n - 1 else i - 1;
            val r: usize = if (i == n - 1) 0 else i + 1;
            val around = up[l] + up[i] + up[r] + mid[l] + mid[r] + down[l] + down[i] + down[r];
            dst[i] = if (around == 3 || (around == 2 && mid[i] == 1)) 1 else 0;
        }
    }
}

var x: u64 = 88172645463325252;

fn next() -> u64 {
    x = x ^ (x << 13);
    x = x ^ (x >> 7);
    x = x ^ (x << 17);
    return x;
}

fn main() -> !void {
    val n = @cast<usize>((std::process::arg(1) ?? "1024").parse_int() catch 1024);
    var a: grid = { n };
    var b: grid = { n };
    try a.cells.reserve(n * n);
    for (i) in 0..n * n {
        val alive: u8 = if (next() % 3 == 0) 1 else 0;
        try a.cells.push(alive);
    }
    try b.cells.resize(n * n, 0);
    for (gen) in 0..=400 {
        if (gen % 100 == 0) {
            std::println("generation {}: {} alive", gen, a.population());
        }
        if (gen == 400) {
            break;
        }
        a.step(&b);
        val t = a;
        a = b;
        b = t;
    }
    var check: u64 = 14695981039346656037;
    for (c) in a.cells.items() {
        check = (check ^ @cast<u64>(c)) *% 1099511628211;
    }
    std::println("checksum {}", check);
}
