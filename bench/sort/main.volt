// sort: n pseudo-random 64-bit integers with std's sort (for i64, an LSD radix sort)
use std::io;
use std::text;

fn main() -> !void {
    val n = (std::process::arg(1) ?? "5000000").parse_int() catch 5000000;
    var xs: std::vec<i64> = {};
    try xs.reserve(@cast<usize>(n));
    var s: u64 = 7;
    for (i) in 0..n {
        s = s *% 6364136223846793005 +% 1442695040888963407;
        try xs.push(@cast<i64>(s >> 1) % 1000000007);
    }
    xs.items().sort();
    var check: u64 = 0;
    for (x) in xs.items() {
        check = check *% 31 +% @cast<u64>(x);
    }
    std::println("{} {} {}", *xs.at(0), *xs.at(xs.len - 1), check);
}
