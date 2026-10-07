// matmul: two n×n matrices of doubles multiplied in i, k, j order (row by row, cache-friendly)
fn main() {
    let n: usize = std::env::args().nth(1).and_then(|a| a.parse().ok()).unwrap_or(1600);
    let nf = n as f64;
    let mut a = vec![0.0f64; n * n];
    let mut b = vec![0.0f64; n * n];
    let mut c = vec![0.0f64; n * n];
    for i in 0..n {
        for j in 0..n {
            a[i * n + j] = (i as f64 - j as f64) / nf;
            b[i * n + j] = (i + 2 * j + 1) as f64 / nf;
        }
    }
    for i in 0..n {
        let row = &mut c[i * n..(i + 1) * n];
        for k in 0..n {
            let aik = a[i * n + k];
            for (cij, bkj) in row.iter_mut().zip(&b[k * n..(k + 1) * n]) {
                *cij += aik * bkj;
            }
        }
    }
    let trace: f64 = (0..n).map(|i| c[i * n + i]).sum();
    let sum: f64 = c.iter().sum();
    println!("{trace:.6} {sum:.6}");
}
