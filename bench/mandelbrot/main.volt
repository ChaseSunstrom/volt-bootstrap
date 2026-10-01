// mandelbrot (after the Benchmarks Game): how many points of an n x n grid stay in the set for 50 steps
use std::io;
use std::text;

fn main() -> void {
    val n = @cast<i32>((std::process::arg(1) ?? "4000").parse_int() catch 4000);
    val nf = @cast<f64>(n);
    var inside: i64 = 0;
    for (y) in 0..n {
        val ci = 2.0 * @cast<f64>(y) / nf - 1.0;
        for (x) in 0..n {
            val cr = 2.0 * @cast<f64>(x) / nf - 1.5;
            var zr = 0.0;
            var zi = 0.0;
            var tr = 0.0;
            var ti = 0.0;
            var i = 0;
            while (i < 50 && tr + ti <= 4.0) {
                zi = 2.0 * zr * zi + ci;
                zr = tr - ti + cr;
                tr = zr * zr;
                ti = zi * zi;
                i += 1;
            }
            if (tr + ti <= 4.0) {
                inside += 1;
            }
        }
    }
    std::println(inside);
}
