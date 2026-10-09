// revcomp (the Benchmarks Game): the reverse complement of a 64 MiB DNA sequence in FASTA lines of
// 60 bases, done nine times between two byte buffers; prints the size, the first line and an FNV-1a
// checksum of the result
struct Rng(u64);

impl Rng {
    fn next(&mut self) -> u64 {
        self.0 ^= self.0 << 13;
        self.0 ^= self.0 >> 7;
        self.0 ^= self.0 << 17;
        self.0
    }
}

// out gets inp's bases from last to first, each complemented, 60 a line
fn revcomp(inp: &[u8], out: &mut [u8], comp: &[u8; 256]) {
    let (mut o, mut col) = (0, 0);
    for &c in inp.iter().rev() {
        if c == b'\n' {
            continue;
        }
        out[o] = comp[c as usize];
        o += 1;
        col += 1;
        if col == 60 {
            out[o] = b'\n';
            o += 1;
            col = 0;
        }
    }
    if col > 0 {
        out[o] = b'\n';
    }
}

fn main() {
    let n: usize = std::env::args().nth(1).and_then(|a| a.parse().ok()).unwrap_or(67108864);
    // each IUPAC code and its complement, upper and lower case
    let (from, to) = (b"ACGTUMRWSYKVHDBNacgtumrwsykvhdbn", b"TGCAAKYWSRMBDHVNTGCAAKYWSRMBDHVN");
    let mut comp = [0u8; 256];
    for (i, c) in comp.iter_mut().enumerate() {
        *c = i as u8;
    }
    for (&f, &t) in from.iter().zip(to) {
        comp[f as usize] = t;
    }
    // the bases: mostly ACGT, some lower case and other codes
    let alphabet = b"ACGTACGTACGTacgtNRYKMSWBDHVnACGT";
    let len = n + n.div_ceil(60);
    let mut a = Vec::with_capacity(len);
    let mut b = vec![0u8; len];
    let mut rng = Rng(88172645463325252);
    for i in 0..n {
        a.push(alphabet[(rng.next() >> 59) as usize]);
        if i % 60 == 59 || i == n - 1 {
            a.push(b'\n');
        }
    }
    for _ in 0..9 {
        revcomp(&a, &mut b, &comp);
        std::mem::swap(&mut a, &mut b);
    }
    let check = a.iter().fold(14695981039346656037u64, |h, &c| (h ^ c as u64).wrapping_mul(1099511628211));
    let first = if a.len() < 60 { a.len() - 1 } else { 60 };
    println!("{n} bases, {} bytes\n{}\n{check}", a.len(), std::str::from_utf8(&a[..first]).unwrap());
}
