// k-nucleotide (the Benchmarks Game): count the k-mers of a long DNA string, k = 1 and 2 as sorted
// frequencies, and five longer ones (up to 18 bases) by building a table for each length; Rust packs
// the bases 2 bits each into a u64 key, counted in a std HashMap
use std::collections::HashMap;

fn count(codes: &[u8], k: usize) -> HashMap<u64, u32> {
    let mask = (1u64 << (2 * k)) - 1;
    let mut key = 0u64;
    let mut counts = HashMap::new();
    for (i, &c) in codes.iter().enumerate() {
        key = ((key << 2) | c as u64) & mask;
        if i + 1 >= k {
            *counts.entry(key).or_insert(0) += 1;
        }
    }
    counts
}

const LETTERS: &[u8; 4] = b"ACGT";

fn frequencies(codes: &[u8], k: usize) {
    let mut all: Vec<(u64, u32)> = count(codes, k).into_iter().collect();
    // most frequent first; same length, so key order is letter order
    all.sort_by(|a, b| b.1.cmp(&a.1).then(a.0.cmp(&b.0)));
    for (key, n) in all {
        let name: String = (0..k).map(|j| LETTERS[((key >> (2 * (k - 1 - j))) & 3) as usize] as char).collect();
        println!("{name} {:.3}", 100.0 * n as f64 / (codes.len() - k + 1) as f64);
    }
    println!();
}

fn code_of(c: u8) -> u8 {
    match c {
        b'A' => 0,
        b'C' => 1,
        b'G' => 2,
        _ => 3,
    }
}

fn occurrences(codes: &[u8], seq: &str) {
    let key = seq.bytes().fold(0u64, |key, c| (key << 2) | code_of(c) as u64);
    println!("{}\t{seq}", count(codes, seq.len()).get(&key).copied().unwrap_or(0));
}

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
    let n: usize = std::env::args().nth(1).and_then(|a| a.parse().ok()).unwrap_or(25000000);
    // the bases at the human genome's frequencies; the generator that made the original input
    // (fasta) repeats every 139968 numbers, so this sequence repeats with that period too
    let period = 139968;
    let mut rng = Rng(88172645463325252);
    let mut dna = Vec::with_capacity(n);
    for i in 0..n {
        let base = if i >= period {
            dna[i - period]
        } else {
            match (rng.next() >> 32) % 1000 {
                r if r < 303 => b'A',
                r if r < 501 => b'C',
                r if r < 699 => b'G',
                _ => b'T',
            }
        };
        dna.push(base);
    }
    let codes: Vec<u8> = dna.iter().map(|&c| code_of(c)).collect();
    frequencies(&codes, 1);
    frequencies(&codes, 2);
    for seq in ["GGT", "GGTA", "GGTATT", "GGTATTTTAATT", "GGTATTTTAATTTATAGT"] {
        occurrences(&codes, seq);
    }
}
