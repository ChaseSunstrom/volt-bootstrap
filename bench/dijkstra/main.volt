// dijkstra: shortest paths over an n x n grid whose edges have random weights, from two corners,
// with a binary heap of (distance, node) and lazy deletion; Volt uses std::vec and std::heap, the
// items ordered by their attached cmp
use std::io;
use std::heap;
use std::text;

var seed: u64 = 88172645463325252;

fn next() -> u64 {
    seed ^= seed << 13;
    seed ^= seed >> 7;
    seed ^= seed << 17;
    return seed;
}

struct item {
    dist: u64;
    node: u32;
}

attach fn cmp(this: item&, o: item&) -> i32 {
    if (this.dist != o.dist) {
        if (this.dist < o.dist) {
            return -1;
        }
        return 1;
    }
    if (this.node < o.node) {
        return -1;
    }
    if (this.node > o.node) {
        return 1;
    }
    return 0;
}

fn shortest(n: usize, weight: u32[..], src: u32, relaxed: u64&) -> !std::vec<u64> {
    var dist: std::vec<u64> = {};
    try dist.resize(n * n, 18446744073709551615);
    val ds = dist.items();
    var h: std::heap<item> = {};
    ds[@cast<usize>(src)] = 0;
    h.push({ dist: 0, node: src });
    while (val cur = h.pop()) {
        val node = @cast<usize>(cur.node);
        if (cur.dist > ds[node]) {
            continue;
        }
        val x = node % n;
        val y = node / n;
        for (d) in @cast<usize>(0)..4 {
            var nx = x;
            var ny = y;
            if (d == 0) {
                if (x + 1 >= n) {
                    continue;
                }
                nx = x + 1;
            } else if (d == 1) {
                if (x == 0) {
                    continue;
                }
                nx = x - 1;
            } else if (d == 2) {
                if (y + 1 >= n) {
                    continue;
                }
                ny = y + 1;
            } else {
                if (y == 0) {
                    continue;
                }
                ny = y - 1;
            }
            val to = ny * n + nx;
            val nd = cur.dist + @cast<u64>(weight[node * 4 + d]);
            if (nd < ds[to]) {
                ds[to] = nd;
                *relaxed += 1;
                h.push({ dist: nd, node: @cast<u32>(to) });
            }
        }
    }
    return dist;
}

fn main() -> !void {
    val n = @cast<usize>((std::process::arg(1) ?? "1500").parse_int() catch 1500);
    val count = n * n;
    var weight: std::vec<u32> = {};
    try weight.reserve(count * 4);
    for (i) in 0..count * 4 {
        try weight.push(@cast<u32>(next() % 100) + 1);
    }
    var relaxed: u64 = 0;
    val sources: u32[2] = { 0, @cast<u32>(count - 1) };
    for (s) in 0..2 {
        val dist = try shortest(n, weight.items(), sources[s], &relaxed);
        var sum: u64 = 0;
        var far: u64 = 0;
        for (d) in dist.items() {
            sum +%= d;
            if (d > far) {
                far = d;
            }
        }
        std::println("from {}: corner {}, farthest {}, sum {}", sources[s], *dist.at(@cast<usize>(sources[1 - s])), far, sum);
    }
    std::println("relaxed {}", relaxed);
}
