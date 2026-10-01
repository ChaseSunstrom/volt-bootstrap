// closures: a map / filter / fold pipeline over an array, many rounds; Volt passes closures to a
// template, which gets a copy with direct calls
use std::io;
use std::text;

<F: type, K: type>
fn pipeline(xs: i64[..], f: F, keep: K) -> i64 {
    var sum: i64 = 0;
    for (x) in xs {
        val y = f(x);
        if (keep(y)) {
            sum += y;
        }
    }
    return sum;
}

fn main() -> !void {
    val rounds = (std::process::arg(1) ?? "1000").parse_int() catch 1000;
    val n: usize = 1000000;
    var xs: std::vec<i64> = {};
    try xs.reserve(n);
    for (i) in 0..n {
        try xs.push(@cast<i64>(i % 1000));
    }
    var total: i64 = 0;
    for (r) in 0..rounds {
        val factor = r % 7 + 2;
        val limit = 5000 - r;
        total += pipeline(xs.items(), |factor| (x: i64) -> i64 { return x * factor + 1; }, |limit| (y: i64) -> bool { return y % 3 != 0 && y < limit; });
    }
    std::println(total);
}
