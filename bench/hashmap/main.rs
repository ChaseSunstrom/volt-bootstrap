// hash map churn: insert n pseudo-random keys, look each up plus as many misses, remove half (std::collections::HashMap)
use std::collections::HashMap;

fn lcg(x: u64) -> u64 {
    x.wrapping_mul(6364136223846793005).wrapping_add(1442695040888963407)
}

fn main() {
    let n: u64 = std::env::args().nth(1).and_then(|a| a.parse().ok()).unwrap_or(5_000_000);
    let mut m: HashMap<u64, u64> = HashMap::new();
    let mut x = 42;
    for i in 0..n {
        x = lcg(x);
        m.insert(x >> 16, i);
    }
    let (mut sum, mut found) = (0u64, 0u64);
    x = 42;
    for _ in 0..n {
        x = lcg(x);
        if let Some(v) = m.get(&(x >> 16)) {
            sum += v;
            found += 1;
        }
        if m.contains_key(&((x >> 16) + 1)) {
            found += 1;
        }
    }
    x = 42;
    let mut removed = 0;
    for _ in (0..n).step_by(2) {
        x = lcg(x);
        if m.remove(&(x >> 16)).is_some() {
            removed += 1;
        }
        x = lcg(x);
    }
    println!("{} {found} {sum} {removed}", m.len());
}
