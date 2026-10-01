// vec_grow: growing arrays one push at a time (no reserve), then summing them, many times over
use std::io;
use std::text;

fn main() -> !void {
    val n = (std::process::arg(1) ?? "20000000").parse_int() catch 20000000;
    var total: u64 = 0;
    for (round) in 0..10 {
        var xs: std::vec<i64> = {};
        for (i) in 0..n {
            try xs.push(i * 3 + round);
        }
        for (x) in xs.items() {
            total +%= @cast<u64>(x);
        }
    }
    std::println(total);
}
