// closures: a map / filter / fold pipeline over an array, many rounds; Rust passes closures to a generic fn
fn pipeline(xs: &[i64], f: impl Fn(i64) -> i64, keep: impl Fn(i64) -> bool) -> i64 {
    xs.iter().map(|&x| f(x)).filter(|&y| keep(y)).sum()
}

fn main() {
    let rounds: i64 = std::env::args().nth(1).and_then(|a| a.parse().ok()).unwrap_or(1000);
    let xs: Vec<i64> = (0..1_000_000).map(|i| i % 1000).collect();
    let mut total = 0i64;
    for r in 0..rounds {
        let (factor, limit) = (r % 7 + 2, 5000 - r);
        total += pipeline(&xs, |x| x * factor + 1, |y| y % 3 != 0 && y < limit);
    }
    println!("{total}");
}
