// btree: an ordered map from u64 to u64 under random inserts (some overwriting), lookups (two in five
// of them hits) and range scans of 100 entries from a random key; prints the size, the hits and a
// checksum of what the lookups and scans saw. Rust uses std's BTreeMap
use std::collections::BTreeMap;

struct Rng(u64);

impl Rng {
    fn next(&mut self) -> u64 {
        self.0 ^= self.0 << 13;
        self.0 ^= self.0 >> 7;
        self.0 ^= self.0 << 17;
        self.0
    }
}

fn main() {
    let n: usize = std::env::args().nth(1).and_then(|a| a.parse().ok()).unwrap_or(2000000);
    let space = 2 * n as u64; // keys are drawn from 0..space
    let mut rng = Rng(88172645463325252);
    let mut t = BTreeMap::new();
    for i in 0..n as u64 {
        t.insert(rng.next() % space, i);
    }
    let mut hits = 0;
    let mut check = 0u64;
    for _ in 0..n {
        if let Some(v) = t.get(&(rng.next() % space)) {
            hits += 1;
            check = check.wrapping_add(*v);
        }
    }
    for _ in 0..n / 10 {
        for (k, v) in t.range(rng.next() % space..).take(100) {
            check = check.wrapping_mul(31).wrapping_add(*k).wrapping_add(*v);
        }
    }
    println!("{} entries, {hits} of {n} lookups found", t.len());
    println!("checksum {check}");
}
