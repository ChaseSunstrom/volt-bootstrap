// life: Conway's game of life on an n x n grid that wraps at the edges (a torus), a byte per cell,
// from a random start for 400 generations; prints the population every 100 generations and a
// checksum of the last grid. Rust keeps each grid in a Vec and walks it a row at a time
fn step(cur: &[u8], out: &mut [u8], n: usize) {
    for (y, out_row) in out.chunks_exact_mut(n).enumerate() {
        let up = &cur[(if y == 0 { n - 1 } else { y - 1 }) * n..][..n];
        let row = &cur[y * n..][..n];
        let down = &cur[(if y == n - 1 { 0 } else { y + 1 }) * n..][..n];
        for (x, cell) in out_row.iter_mut().enumerate() {
            let l = if x == 0 { n - 1 } else { x - 1 };
            let r = if x == n - 1 { 0 } else { x + 1 };
            let around = up[l] + up[x] + up[r] + row[l] + row[r] + down[l] + down[x] + down[r];
            *cell = (around == 3 || (around == 2 && row[x] == 1)) as u8;
        }
    }
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
    let n: usize = std::env::args().nth(1).and_then(|a| a.parse().ok()).unwrap_or(1024);
    let mut rng = Rng(88172645463325252);
    let mut a: Vec<u8> = (0..n * n).map(|_| (rng.next() % 3 == 0) as u8).collect();
    let mut b = vec![0u8; n * n];
    for generation in 0..=400 {
        if generation % 100 == 0 {
            println!("generation {generation}: {} alive", a.iter().map(|&c| c as usize).sum::<usize>());
        }
        if generation == 400 {
            break;
        }
        step(&a, &mut b, n);
        std::mem::swap(&mut a, &mut b);
    }
    let check = a.iter().fold(14695981039346656037u64, |h, &c| (h ^ c as u64).wrapping_mul(1099511628211));
    println!("checksum {check}");
}
