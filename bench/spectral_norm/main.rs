// spectral-norm (the Benchmarks Game): the largest eigenvalue of an infinite matrix, by power iteration
fn a(i: usize, j: usize) -> f64 {
    1.0 / ((i + j) * (i + j + 1) / 2 + i + 1) as f64
}

fn times(v: &[f64], out: &mut [f64]) {
    for (i, o) in out.iter_mut().enumerate() {
        *o = v.iter().enumerate().map(|(j, x)| a(i, j) * x).sum();
    }
}

fn times_t(v: &[f64], out: &mut [f64]) {
    for (i, o) in out.iter_mut().enumerate() {
        *o = v.iter().enumerate().map(|(j, x)| a(j, i) * x).sum();
    }
}

fn ata(v: &[f64], out: &mut [f64], tmp: &mut [f64]) {
    times(v, tmp);
    times_t(tmp, out);
}

fn main() {
    let n: usize = std::env::args().nth(1).and_then(|a| a.parse().ok()).unwrap_or(5500);
    let mut u = vec![1.0; n];
    let mut v = vec![0.0; n];
    let mut tmp = vec![0.0; n];
    for _ in 0..10 {
        ata(&u, &mut v, &mut tmp);
        ata(&v, &mut u, &mut tmp);
    }
    let vbv: f64 = u.iter().zip(&v).map(|(x, y)| x * y).sum();
    let vv: f64 = v.iter().map(|y| y * y).sum();
    println!("{:.9}", (vbv / vv).sqrt());
}
