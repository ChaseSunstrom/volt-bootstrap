// vec_grow: growing arrays one push at a time (no reserve), then summing them, many times over
fn main() {
    let n: i64 = std::env::args().nth(1).and_then(|a| a.parse().ok()).unwrap_or(20000000);
    let mut total: u64 = 0;
    for round in 0..10 {
        let mut xs = Vec::new();
        for i in 0..n {
            xs.push(i * 3 + round);
        }
        total = xs.iter().fold(total, |t, &x| t.wrapping_add(x as u64));
    }
    println!("{total}");
}
