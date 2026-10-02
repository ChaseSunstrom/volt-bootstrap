// matmul: two n×n matrices of doubles multiplied in i, k, j order (row by row, cache-friendly)
use std::io;
use std::text;

fn main() -> !void {
    val n = @cast<usize>((std::process::arg(1) ?? "1600").parse_int() catch 1600);
    var a: std::vec<f64> = {};
    var b: std::vec<f64> = {};
    var c: std::vec<f64> = {};
    try a.reserve(n * n);
    try b.reserve(n * n);
    for (i) in 0..n {
        for (j) in 0..n {
            try a.push((@cast<f64>(i) - @cast<f64>(j)) / @cast<f64>(n));
            try b.push(@cast<f64>(i + 2 * j + 1) / @cast<f64>(n));
        }
    }
    try c.resize(n * n, 0.0); // zeros, as C's calloc
    val x = a.items();
    val y = b.items();
    val z = c.items();
    for (i) in 0..n {
        for (k) in 0..n {
            val aik = x[i * n + k];
            for (j) in 0..n {
                z[i * n + j] += aik * y[k * n + j];
            }
        }
    }
    var trace = 0.0;
    var sum = 0.0;
    for (i) in 0..n {
        trace += z[i * n + i];
    }
    for (v) in z {
        sum += v;
    }
    std::println("{:.6} {:.6}", trace, sum);
}
