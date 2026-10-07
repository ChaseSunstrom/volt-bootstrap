// lz77: compress a repetitive text with LZ77 (a hash table of recent positions, chains of at most 8
// probes, a 64 KiB window), decompress it and check the round trip; Rust builds Vec<u8>s from
// slices, and the decoder returns None for corrupt input

// the format: a byte c < 128 is followed by c + 1 literal bytes; c >= 128 is a match of
// c - 128 + MIN_MATCH bytes, then its distance back (1..MAX_DIST) in two bytes, low first
const HASH_BITS: u32 = 16;
const WINDOW: usize = 1 << 16;
const MIN_MATCH: usize = 4;
const MAX_MATCH: usize = MIN_MATCH + 127;
const MAX_CHAIN: usize = 8;
const MAX_DIST: usize = WINDOW - 1;

fn hash4(p: &[u8]) -> usize {
    let v = u32::from_le_bytes([p[0], p[1], p[2], p[3]]);
    (v.wrapping_mul(2654435761) >> (32 - HASH_BITS)) as usize
}

fn put_literals(out: &mut Vec<u8>, lits: &[u8]) {
    for chunk in lits.chunks(128) {
        out.push((chunk.len() - 1) as u8);
        out.extend_from_slice(chunk);
    }
}

fn compress(input: &[u8]) -> Vec<u8> {
    let n = input.len();
    let mut head = vec![-1i32; 1 << HASH_BITS];
    let mut prev = vec![0i32; WINDOW];
    let mut out = Vec::with_capacity(n + n / 128 + 16);
    let (mut i, mut lit) = (0, 0);
    while i + MIN_MATCH <= n {
        let h = hash4(&input[i..]);
        let (mut best, mut dist) = (0, 0);
        let limit = (n - i).min(MAX_MATCH);
        let mut cand = head[h];
        let mut probes = 0;
        while cand >= 0 && i - cand as usize <= MAX_DIST && probes < MAX_CHAIN {
            let c = cand as usize;
            let len = input[c..c + limit].iter().zip(&input[i..i + limit]).take_while(|(a, b)| a == b).count();
            if len > best {
                best = len;
                dist = i - c;
                if len == limit {
                    break;
                }
            }
            cand = prev[c & (WINDOW - 1)];
            probes += 1;
        }
        prev[i & (WINDOW - 1)] = head[h];
        head[h] = i as i32;
        if best >= MIN_MATCH {
            put_literals(&mut out, &input[lit..i]);
            out.extend_from_slice(&[(128 + best - MIN_MATCH) as u8, dist as u8, (dist >> 8) as u8]);
            // the positions inside the match go into the table too
            let mut j = i + 1;
            while j < i + best && j + MIN_MATCH <= n {
                let hj = hash4(&input[j..]);
                prev[j & (WINDOW - 1)] = head[hj];
                head[hj] = j as i32;
                j += 1;
            }
            i += best;
            lit = i;
        } else {
            i += 1;
        }
    }
    put_literals(&mut out, &input[lit..]);
    out
}

// decompresses src into at most cap bytes, or None when the input is corrupt
fn decompress(src: &[u8], cap: usize) -> Option<Vec<u8>> {
    let mut out = Vec::with_capacity(cap);
    let mut p = 0;
    while p < src.len() {
        let c = src[p] as usize;
        p += 1;
        if c < 128 {
            let k = c + 1;
            if src.len() - p < k || cap - out.len() < k {
                return None;
            }
            out.extend_from_slice(&src[p..p + k]);
            p += k;
        } else {
            if src.len() - p < 2 {
                return None;
            }
            let (len, dist) = (c - 128 + MIN_MATCH, src[p] as usize | (src[p + 1] as usize) << 8);
            p += 2;
            if dist == 0 || dist > out.len() || cap - out.len() < len {
                return None;
            }
            // may overlap what it writes: a byte at a time
            let from = out.len() - dist;
            for k in 0..len {
                out.push(out[from + k]);
            }
        }
    }
    Some(out)
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
    let n: usize = std::env::args().nth(1).and_then(|a| a.parse().ok()).unwrap_or(64 << 20);
    let mut rng = Rng(88172645463325252);
    // the text: words from a 1024-word vocabulary (the first ones the most common), and now and
    // then a phrase repeated from up to 32 KiB back
    let words: Vec<Vec<u8>> = (0..1024)
        .map(|_| {
            let len = 2 + rng.next() % 8;
            (0..len).map(|_| b'a' + (rng.next() % 26) as u8).collect()
        })
        .collect();
    let mut text = Vec::with_capacity(n + 128);
    while text.len() < n {
        let r = rng.next();
        if r % 16 == 0 && text.len() >= 64 {
            let span = text.len().min(32768) as u64;
            let dist = 1 + (rng.next() % span) as usize;
            let count = 16 + rng.next() % 48;
            for _ in 0..count {
                text.push(text[text.len() - dist]);
            }
        } else {
            let w = (((r >> 8) % 1024) * ((r >> 20) % 1024) / 1024) as usize;
            text.extend_from_slice(&words[w]);
            match (r >> 40) % 16 {
                0 => text.extend_from_slice(b".\n"),
                1 => text.extend_from_slice(b", "),
                _ => text.push(b' '),
            }
        }
    }
    let text = &text[..n];
    let packed = compress(text);
    if decompress(&packed, n).as_deref() != Some(text) {
        eprintln!("round trip failed");
        std::process::exit(1);
    }
    let check = packed.iter().fold(14695981039346656037u64, |h, &b| (h ^ b as u64).wrapping_mul(1099511628211));
    println!("{n} {} {check}", packed.len());
}
