// hash map churn: insert n pseudo-random keys, look each up plus as many misses, remove half
// (std::map)
use std::io;
use std::text;

fn main() -> void {
    val n = (std::process::arg(1) ?? "5000000").parse_int() catch 5000000;
    var m: std::map<u64, u64> = {};
    var x: u64 = 42;
    var sum: u64 = 0;
    var found: u64 = 0;
    for (i) in 0..n {
        x = x *% 6364136223846793005 +% 1442695040888963407;
        m.put(x >> 16, @cast<u64>(i));
    }
    x = 42;
    for (i) in 0..n {
        x = x *% 6364136223846793005 +% 1442695040888963407;
        val v = m.get(x >> 16);
        if (v != null) {
            sum +%= *v;
            found += 1;
        }
        if (m.contains((x >> 16) + 1)) {
            found += 1;
        }
    }
    x = 42;
    var removed = 0;
    var i: i64 = 0;
    while (i < n) {
        x = x *% 6364136223846793005 +% 1442695040888963407;
        if (m.remove(x >> 16) != null) {
            removed += 1;
        }
        x = x *% 6364136223846793005 +% 1442695040888963407;
        i += 2;
    }
    std::println("{} {} {} {}", m.len, found, sum, removed);
}
