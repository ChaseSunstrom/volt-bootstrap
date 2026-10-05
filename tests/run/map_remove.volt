// std::map under many puts and removes, checked against a plain array: a removal shifts the entries
// after it back, and every key has to stay reachable (integer keys, which cluster, and string keys)
use std::io;
use std::text;

var seed: u64 = 88172645463325252;

fn next() -> u64 {
    seed = seed ^ (seed << 13);
    seed = seed ^ (seed >> 7);
    seed = seed ^ (seed << 17);
    return seed;
}

fn main() -> !void {
    // keys 0..3000 into a map that grows and shrinks; want[k] is k's value, or -1 when it's absent
    var m: std::map<u64, i64> = {};
    var want: i64[3000] = { -1; 3000 };
    var bad = 0;
    for (round) in 0..200000 {
        val k = next() % 3000;
        if (next() % 3 == 0) {
            val got = m.remove(k);
            val had = want[k] >= 0;
            if ((got != null) != had) {
                bad += 1;
            }
            want[k] = -1;
        } else {
            m.put(k, @cast<i64>(round));
            want[k] = @cast<i64>(round);
        }
    }
    var held: usize = 0;
    for (k) in 0..3000 {
        val v = m.get(@cast<u64>(k));
        if (want[k] >= 0) {
            held += 1;
            if (v == null || *v != want[k]) {
                bad += 1;
            }
        } else if (v != null) {
            bad += 1;
        }
    }
    std::println("{} keys, len {}, bad {}", held, m.len, bad);

    // owned string keys and values, removed in a different order than they went in
    var s: std::map<std::string, std::string> = {};
    for (i) in 0..500 {
        s.put(std::fmt::format("key{}", i), std::fmt::format("value{}", i * 7));
    }
    for (i) in 0..500 {
        if (i % 3 != 1) {
            val gone = s.remove(std::fmt::format("key{}", (i * 37) % 500));
        }
    }
    var found = 0;
    for (i) in 0..500 {
        if (val v = s.get(std::fmt::format("key{}", i))) {
            val w = std::fmt::format("value{}", i * 7);
            if (v.as_str() == w.as_str()) {
                found += 1;
            }
        }
    }
    std::println("{} of {} strings", found, s.len);
}
// flags: --leak-check
// expect: 1982 keys, len 1982, bad 0
// expect: 167 of 167 strings
