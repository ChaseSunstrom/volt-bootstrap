// fannkuch-redux (the Benchmarks Game): pancake flips over every permutation of 1..n
fn main() {
    let n: usize = std::env::args().nth(1).and_then(|a| a.parse().ok()).unwrap_or(11);
    let mut perm1: [usize; 16] = std::array::from_fn(|i| i);
    let mut count = [0usize; 16];
    let (mut max_flips, mut checksum, mut perm_count, mut r) = (0i32, 0i32, 0u64, n);
    loop {
        while r != 1 {
            count[r - 1] = r;
            r -= 1;
        }
        let mut perm = perm1;
        let mut flips = 0;
        while perm[0] != 0 {
            let k = perm[0];
            perm[..=k].reverse();
            flips += 1;
        }
        max_flips = max_flips.max(flips);
        checksum += if perm_count % 2 == 0 { flips } else { -flips };
        loop {
            if r == n {
                println!("{checksum}\nPfannkuchen({n}) = {max_flips}");
                return;
            }
            perm1[..=r].rotate_left(1);
            count[r] -= 1;
            if count[r] > 0 {
                break;
            }
            r += 1;
        }
        perm_count += 1;
    }
}
