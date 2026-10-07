// mandelbrot (after the Benchmarks Game): how many points of an n x n grid stay in the set for 50 steps
fn main() {
    let n: i32 = std::env::args().nth(1).and_then(|a| a.parse().ok()).unwrap_or(4000);
    let mut inside: i64 = 0;
    for y in 0..n {
        let ci = 2.0 * y as f64 / n as f64 - 1.0;
        for x in 0..n {
            let cr = 2.0 * x as f64 / n as f64 - 1.5;
            let (mut zr, mut zi, mut tr, mut ti) = (0.0, 0.0, 0.0, 0.0);
            let mut i = 0;
            while i < 50 && tr + ti <= 4.0 {
                zi = 2.0 * zr * zi + ci;
                zr = tr - ti + cr;
                tr = zr * zr;
                ti = zi * zi;
                i += 1;
            }
            if tr + ti <= 4.0 {
                inside += 1;
            }
        }
    }
    println!("{inside}");
}
