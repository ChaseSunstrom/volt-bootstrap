// print: half a million doubles in [1, 2), then half a million integers, a line each (a float prints
// as the shortest text that reads back as the same value)
use std::io;
use std::text;

var x: u64 = 88172645463325252;

fn next() -> u64 {
    x = x ^ (x << 13);
    x = x ^ (x >> 7);
    x = x ^ (x << 17);
    return x;
}

fn main() -> void {
    val n = (std::process::arg(1) ?? "500000").parse_int() catch 500000;
    for (i) in 0..n {
        std::println(1.0 + @cast<f64>(next() >> 12) / 4503599627370496.0);
    }
    for (i) in 0..n {
        std::println(@cast<i64>(next() >> 1));
    }
}
