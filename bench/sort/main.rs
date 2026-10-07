// sort: n pseudo-random 64-bit integers with slice::sort, which is stable (Volt's sort is stable too)
fn main() {
    let n: usize = std::env::args().nth(1).and_then(|a| a.parse().ok()).unwrap_or(5000000);
    let mut s: u64 = 7;
    let mut xs: Vec<i64> = (0..n)
        .map(|_| {
            s = s.wrapping_mul(6364136223846793005).wrapping_add(1442695040888963407);
            (s >> 1) as i64 % 1000000007
        })
        .collect();
    xs.sort();
    let check = xs.iter().fold(0u64, |c, &x| c.wrapping_mul(31).wrapping_add(x as u64));
    println!("{} {} {}", xs[0], xs[n - 1], check);
}
