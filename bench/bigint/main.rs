// bigint: arbitrary-precision integers in base 1e9 limbs: n! by repeated small multiplies, the m-th Fibonacci number by repeated additions, and a schoolbook product of two big numbers
const BASE: u32 = 1_000_000_000;

/// limbs, least significant first
struct Big(Vec<u32>);

impl Big {
    fn from(v: u32) -> Big {
        Big(vec![v])
    }

    fn mul_small(&mut self, k: u32) {
        let mut carry = 0u64;
        for l in &mut self.0 {
            let x = *l as u64 * k as u64 + carry;
            *l = (x % BASE as u64) as u32;
            carry = x / BASE as u64;
        }
        while carry != 0 {
            self.0.push((carry % BASE as u64) as u32);
            carry /= BASE as u64;
        }
    }

    fn add(&self, other: &Big) -> Big {
        let (l, s) = if self.0.len() >= other.0.len() { (&self.0, &other.0) } else { (&other.0, &self.0) };
        let mut r = Vec::with_capacity(l.len() + 1);
        let mut carry = 0;
        for (i, &x) in l.iter().enumerate() {
            let x = x + s.get(i).copied().unwrap_or(0) + carry;
            carry = (x >= BASE) as u32;
            r.push(if carry != 0 { x - BASE } else { x });
        }
        if carry != 0 {
            r.push(1);
        }
        Big(r)
    }

    fn mul(&self, other: &Big) -> Big {
        let (a, b) = (&self.0, &other.0);
        let mut r = vec![0u32; a.len() + b.len()];
        for (i, &ai) in a.iter().enumerate() {
            let mut carry = 0u64;
            for (j, &bj) in b.iter().enumerate() {
                let x = r[i + j] as u64 + ai as u64 * bj as u64 + carry;
                r[i + j] = (x % BASE as u64) as u32;
                carry = x / BASE as u64;
            }
            r[i + b.len()] = carry as u32;
        }
        while r.len() > 1 && r[r.len() - 1] == 0 {
            r.pop();
        }
        Big(r)
    }

    /// digit count and digit sum
    fn report(&self, what: &str) {
        let mut sum = 0u64;
        for &l in &self.0 {
            let mut x = l;
            while x != 0 {
                sum += (x % 10) as u64;
                x /= 10;
            }
        }
        let mut digits = (self.0.len() - 1) * 9;
        let mut top = self.0[self.0.len() - 1];
        while top != 0 {
            digits += 1;
            top /= 10;
        }
        println!("{what}: {digits} digits, digit sum {sum}");
    }
}

fn main() {
    let n: u32 = std::env::args().nth(1).and_then(|a| a.parse().ok()).unwrap_or(20000);
    let mut f = Big::from(1);
    for k in 2..=n {
        f.mul_small(k);
    }
    f.report("factorial");
    // fib[i % 2] steps through the Fibonacci numbers, each sum replacing the older of the two
    let mut fib = [Big::from(0), Big::from(1)];
    for i in 0..n * 10 {
        fib[(i % 2) as usize] = fib[0].add(&fib[1]);
    }
    fib[1].report("fibonacci");
    f.mul(&fib[1]).report("product");
}
