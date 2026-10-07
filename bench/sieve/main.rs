// sieve: the primes below n with the sieve of Eratosthenes over a byte array
fn main() {
    let n: usize = std::env::args().nth(1).and_then(|a| a.parse().ok()).unwrap_or(200000000);
    let mut prime = vec![true; n];
    prime[0] = false;
    prime[1] = false;
    let mut i = 2;
    while i * i < n {
        if prime[i] {
            for p in prime[i * i..].iter_mut().step_by(i) {
                *p = false;
            }
        }
        i += 1;
    }
    let (mut count, mut last) = (0, 0);
    for (i, &p) in prime.iter().enumerate() {
        if p {
            count += 1;
            last = i;
        }
    }
    println!("{count} {last}");
}
