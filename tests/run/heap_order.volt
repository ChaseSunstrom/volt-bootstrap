// std::heap under random pushes and pops: every pop gives the smallest element left, for numbers
// and for owned strings (the pop moves the hole down, then the last element back up)
use std::io;
use std::text;

var seed: u64 = 88172645463325252;

fn next() -> u64 {
    seed = seed ^ (seed << 13);
    seed = seed ^ (seed >> 7);
    seed = seed ^ (seed << 17);
    return seed;
}

fn main() -> void {
    var h: std::heap<u64> = {};
    var bad = 0;
    var pops = 0;
    // pushes and pops mixed: each pop gives the minimum of a shadow array of what's held
    var shadow: std::vec<u64> = {};
    for (round) in 0..20000 {
        if (next() % 3 == 0 && shadow.len > 0) {
            val got = h.pop() ?? 0;
            var at: usize = 0;
            for (x, i) in shadow.items() {
                if (x < shadow.items()[at]) {
                    at = i;
                }
            }
            if (got != shadow.items()[at]) {
                bad += 1;
            }
            val gone = shadow.swap_remove(at);
            pops += 1;
        } else {
            val v = next() % 1000;
            h.push(v);
            shadow.push(v) catch @panic("out of memory");
        }
    }
    var last: u64 = 0;
    while (val x = h.pop()) {
        if (x < last) {
            bad += 1;
        }
        last = x;
        pops += 1;
    }
    std::println("{} pops, bad {}", pops, bad);

    var s: std::heap<std::string> = {};
    for (i) in 0..300 {
        s.push(std::fmt::format("w{}", (i * 7919) % 1000));
    }
    var prev = std::string::from("");
    var sorted = 0;
    var n = 0;
    while (val w = s.pop()) {
        if (prev.as_str().cmp(w.as_str()) <= 0) {
            sorted += 1;
        }
        prev = w;
        n += 1;
    }
    std::println("{} of {} strings in order", sorted, n);
}
// flags: --leak-check
// expect: 13325 pops, bad 0
// expect: 300 of 300 strings in order
