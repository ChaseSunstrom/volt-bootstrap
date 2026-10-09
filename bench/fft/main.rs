// fft: an iterative radix-2 FFT over complex doubles: a random signal of n points (a power of two)
// taken to its spectrum and back sixteen times, then checked against the original; prints the
// spectrum's mean energy and two of its points, and the signal's sum. The twiddles come from
// half-angle formulas (sqrt only, which every language rounds the same) and products, not from sin
// and cos. Rust's Complex implements Add, Sub and Mul
use std::ops::{Add, Mul, Sub};

#[derive(Clone, Copy, Default)]
struct Complex {
    re: f64,
    im: f64,
}

impl Add for Complex {
    type Output = Complex;
    fn add(self, o: Complex) -> Complex {
        Complex { re: self.re + o.re, im: self.im + o.im }
    }
}

impl Sub for Complex {
    type Output = Complex;
    fn sub(self, o: Complex) -> Complex {
        Complex { re: self.re - o.re, im: self.im - o.im }
    }
}

impl Mul for Complex {
    type Output = Complex;
    fn mul(self, o: Complex) -> Complex {
        Complex { re: self.re * o.re - self.im * o.im, im: self.re * o.im + self.im * o.re }
    }
}

impl Mul<f64> for Complex {
    type Output = Complex;
    fn mul(self, k: f64) -> Complex {
        Complex { re: self.re * k, im: self.im * k }
    }
}

// e^(-2 pi i j / n) for j < n / 2: the table for each len = 2, 4, ... n from the one before, its even
// entries the old ones and its odd ones those times e^(-2 pi i / len)
fn twiddles(n: usize) -> Vec<Complex> {
    let mut tw = vec![Complex::default(); n / 2];
    tw[0] = Complex { re: 1.0, im: 0.0 };
    let (mut c, mut s) = (0.0f64, 1.0f64); // cos and sin of 2 pi / len
    let mut len = 4;
    while len <= n {
        if len > 4 {
            c = ((1.0 + c) / 2.0).sqrt();
            s /= 2.0 * c;
        }
        let w = Complex { re: c, im: -s };
        for j in (0..len / 4).rev() {
            tw[2 * j + 1] = tw[j] * w;
            tw[2 * j] = tw[j];
        }
        len *= 2;
    }
    tw
}

fn fft(a: &mut [Complex], tw: &[Complex]) {
    let n = a.len();
    let mut j = 0;
    for i in 1..n {
        let mut bit = n >> 1;
        while j & bit != 0 {
            j ^= bit;
            bit >>= 1;
        }
        j ^= bit;
        if i < j {
            a.swap(i, j);
        }
    }
    let mut len = 2;
    while len <= n {
        let (half, step) = (len / 2, n / len);
        for block in a.chunks_exact_mut(len) {
            let (lo, hi) = block.split_at_mut(half);
            for (j, (u, v)) in lo.iter_mut().zip(hi.iter_mut()).enumerate() {
                let t = *v * tw[j * step];
                (*u, *v) = (*u + t, *u - t);
            }
        }
        len *= 2;
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

    fn unit(&mut self) -> f64 {
        (self.next() >> 11) as f64 / 9007199254740992.0 - 0.5
    }
}

fn main() {
    let n: usize = std::env::args().nth(1).and_then(|a| a.parse().ok()).unwrap_or(1048576);
    let mut rng = Rng(88172645463325252);
    let signal: Vec<Complex> = (0..n)
        .map(|_| {
            let re = rng.unit();
            Complex { re, im: rng.unit() }
        })
        .collect();
    let mut a = signal.clone();
    let tw = twiddles(n);
    let inv: Vec<Complex> = tw.iter().map(|w| Complex { re: w.re, im: -w.im }).collect();
    let scale = 1.0 / n as f64;
    let mut energy = 0.0;
    let (mut low, mut mid) = (Complex::default(), Complex::default());
    for round in 0..16 {
        fft(&mut a, &tw);
        if round == 0 {
            energy = a.iter().fold(0.0, |e, v| e + (v.re * v.re + v.im * v.im));
            low = a[1];
            mid = a[n / 3];
        }
        fft(&mut a, &inv);
        for v in a.iter_mut() {
            *v = *v * scale;
        }
    }
    let mut err = 0.0f64;
    let mut sum = 0.0;
    for (v, s) in a.iter().zip(&signal) {
        err = err.max((v.re - s.re).abs() + (v.im - s.im).abs());
        sum += v.re + v.im;
    }
    if err > 1e-9 {
        eprintln!("round trips drifted by {err}");
        std::process::exit(1);
    }
    println!("{n} points, mean energy {:.6}", energy / n as f64);
    println!("X[1] = ({:.6}, {:.6}), X[n/3] = ({:.6}, {:.6})", low.re, low.im, mid.re, mid.im);
    println!("signal sum after 16 round trips {sum:.6}");
}
