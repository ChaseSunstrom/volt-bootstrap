// levenshtein: edit distances between many pairs of strings, each a random string of 64 to 191
// letters and a copy with random substitutions, deletions and insertions, by the dynamic program
// over one row; prints the number of pairs, the sum and the largest of the distances, and a checksum
// of them all
fn distance(a: &[u8], b: &[u8], row: &mut Vec<u32>) -> u32 {
    row.clear();
    row.extend(0..=b.len() as u32);
    for (i, &ca) in a.iter().enumerate() {
        let mut diag = row[0];
        row[0] = i as u32 + 1;
        for (j, &cb) in b.iter().enumerate() {
            let up = row[j + 1];
            row[j + 1] = (diag + (ca != cb) as u32).min(up + 1).min(row[j] + 1);
            diag = up;
        }
    }
    row[b.len()]
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
    let pairs: usize = std::env::args().nth(1).and_then(|a| a.parse().ok()).unwrap_or(40000);
    let letters = b"abcdefgh";
    let mut rng = Rng(88172645463325252);
    let (mut a, mut b, mut row) = (Vec::new(), Vec::new(), Vec::new());
    let (mut total, mut check, mut most) = (0u64, 0u64, 0u32);
    for _ in 0..pairs {
        let la = 64 + rng.next() % 128;
        a.clear();
        for _ in 0..la {
            a.push(letters[(rng.next() % 8) as usize]);
        }
        // b: a with about one letter in 8 changed, one in 16 dropped and one in 16 inserted
        b.clear();
        for &c in &a {
            let r = rng.next() % 16;
            if r == 0 {
                continue;
            }
            if r == 1 {
                b.push(letters[(rng.next() % 8) as usize]);
            }
            b.push(if r == 2 || r == 3 { letters[(rng.next() % 8) as usize] } else { c });
        }
        let d = distance(&a, &b, &mut row);
        total += d as u64;
        most = most.max(d);
        check = check.wrapping_mul(31).wrapping_add(d as u64);
    }
    println!("{pairs} pairs, total distance {total}, largest {most}");
    println!("checksum {check}");
}
