// fasta (the Benchmarks Game): generate three DNA sequences, n*2 bases repeating the ALU string, then
// n*3 and n*5 bases drawn by a linear congruential generator from cumulative probability tables, in
// FASTA lines of 60; prints each one's header, length and an FNV-1a checksum of its lines in place of
// the text. Rust builds the cumulative tables in a const fn
const ALU: &[u8] = b"GGCCGGGCGCGGTGGCTCACGCCTGTAATCCCAGCACTTTGGGAGGCCGAGGCGGGCGGATCACCTGAGGTCAGGAGTTCGAGACCAGCC\
TGGCCAACATGGTGAAACCCCGTCTCTACTAAAAATACAAAAATTAGCCGGGCGTGGTGGCGCGCGCCTGTAATCCCAGCTACTCGGGAG\
GCTGAGGCAGGAGAATCGCTTGAACCCGGGAGGCGGAGGTTGCAGTGAGCCGAGATCGCGCCACTGCACTCCAGCCTGGGCGACAGAGCGA\
GACTCCGTCTCAAAAA";

// each probability becomes the sum of the ones up to it
const fn cumulative<const N: usize>(mut t: [(u8, f64); N]) -> [(u8, f64); N] {
    let mut sum = 0.0;
    let mut i = 0;
    while i < N {
        sum += t[i].1;
        t[i].1 = sum;
        i += 1;
    }
    t
}

const IUB: [(u8, f64); 15] = cumulative([
    (b'a', 0.27), (b'c', 0.12), (b'g', 0.12), (b't', 0.27), (b'B', 0.02), (b'D', 0.02), (b'H', 0.02), (b'K', 0.02),
    (b'M', 0.02), (b'N', 0.02), (b'R', 0.02), (b'S', 0.02), (b'V', 0.02), (b'W', 0.02), (b'Y', 0.02),
]);

const HOMO_SAPIENS: [(u8, f64); 4] = cumulative([(b'a', 0.3029549426680), (b'c', 0.1979883004921), (b'g', 0.1975473066391), (b't', 0.3015094502008)]);

const IM: u32 = 139968;
const IA: u32 = 3877;
const IC: u32 = 29573;

struct Lcg(u32);

impl Lcg {
    fn unit(&mut self) -> f64 {
        self.0 = (self.0 * IA + IC) % IM;
        self.0 as f64 / IM as f64
    }
}

fn fnv(h: u64, s: &[u8]) -> u64 {
    s.iter().fold(h, |h, &c| (h ^ c as u64).wrapping_mul(1099511628211))
}

fn repeat(header: &str, s: &[u8], n: usize) {
    let mut pos = 0;
    let mut line = [0u8; 61];
    let mut h = 14695981039346656037u64;
    let mut done = 0;
    while done < n {
        let m = (n - done).min(60);
        for c in &mut line[..m] {
            *c = s[pos];
            pos += 1;
            if pos == s.len() {
                pos = 0;
            }
        }
        line[m] = b'\n';
        h = fnv(h, &line[..=m]);
        done += m;
    }
    println!("{header}: {n} bases, checksum {h}");
}

fn random_bases(header: &str, t: &[(u8, f64)], rng: &mut Lcg, n: usize) {
    let mut line = [0u8; 61];
    let mut h = 14695981039346656037u64;
    let mut done = 0;
    while done < n {
        let m = (n - done).min(60);
        for c in &mut line[..m] {
            let r = rng.unit();
            let mut k = 0;
            while k < t.len() - 1 && r >= t[k].1 {
                k += 1;
            }
            *c = t[k].0;
        }
        line[m] = b'\n';
        h = fnv(h, &line[..=m]);
        done += m;
    }
    println!("{header}: {n} bases, checksum {h}");
}

fn main() {
    let n: usize = std::env::args().nth(1).and_then(|a| a.parse().ok()).unwrap_or(10000000);
    let mut rng = Lcg(42);
    repeat(">ONE Homo sapiens alu", ALU, n * 2);
    random_bases(">TWO IUB ambiguity codes", &IUB, &mut rng, n * 3);
    random_bases(">THREE Homo sapiens frequency", &HOMO_SAPIENS, &mut rng, n * 5);
}
