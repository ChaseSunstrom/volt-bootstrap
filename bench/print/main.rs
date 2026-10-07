// print: half a million doubles in [1, 2) as the shortest text that reads back as the same value
// (Rust's Display for f64), then half a million integers, a line each
use std::io::{BufWriter, Write};

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
    let n: u64 = std::env::args().nth(1).and_then(|a| a.parse().ok()).unwrap_or(500000);
    let mut rng = Rng(88172645463325252);
    let mut out = BufWriter::new(std::io::stdout().lock());
    for _ in 0..n {
        let v = 1.0 + (rng.next() >> 12) as f64 / 4503599627370496.0;
        writeln!(out, "{v}").unwrap();
    }
    for _ in 0..n {
        writeln!(out, "{}", rng.next() >> 1).unwrap();
    }
}
