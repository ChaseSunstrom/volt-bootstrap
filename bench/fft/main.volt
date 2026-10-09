// fft: an iterative radix-2 FFT over complex doubles: a random signal of n points (a power of two)
// taken to its spectrum and back sixteen times, then checked against the original; prints the
// spectrum's mean energy and two of its points, and the signal's sum. The twiddles come from
// half-angle formulas (sqrt only, which every language rounds the same) and products, not from sin
// and cos. Volt attaches + - * to a complex struct
use std::io;
use std::math;
use std::text;

struct complex {
    re: f64;
    im: f64;
}

attach operator +(this: complex, o: complex) -> complex {
    return { re: this.re + o.re, im: this.im + o.im };
}

attach operator -(this: complex, o: complex) -> complex {
    return { re: this.re - o.re, im: this.im - o.im };
}

attach operator *(this: complex, o: complex) -> complex {
    return { re: this.re * o.re - this.im * o.im, im: this.re * o.im + this.im * o.re };
}

attach operator *(this: complex, k: f64) -> complex {
    return { re: this.re * k, im: this.im * k };
}

// e^(-2 pi i j / n) for j < n / 2: the table for each len = 2, 4, ... n from the one before, its even
// entries the old ones and its odd ones those times e^(-2 pi i / len)
fn twiddles(tw: complex[..], n: usize) -> void {
    tw[0] = { re: 1.0, im: 0.0 };
    var c = 0.0; // cos and sin of 2 pi / len
    var s = 1.0;
    var len: usize = 4;
    while (len <= n) {
        if (len > 4) {
            c = std::math::sqrt((1.0 + c) / 2.0);
            s = s / (2.0 * c);
        }
        val w: complex = { re: c, im: -s };
        var j = len / 4;
        while (j > 0) {
            j -= 1;
            tw[2 * j + 1] = tw[j] * w;
            tw[2 * j] = tw[j];
        }
        len *= 2;
    }
}

fn fft(a: complex[..], tw: complex[..]) -> void {
    val n = a.len;
    var j: usize = 0;
    for (i) in 1..n {
        var bit = n >> 1;
        while ((j & bit) != 0) {
            j ^= bit;
            bit >>= 1;
        }
        j ^= bit;
        if (i < j) {
            val t = a[i];
            a[i] = a[j];
            a[j] = t;
        }
    }
    var len: usize = 2;
    while (len <= n) {
        val half = len / 2;
        val step = n / len;
        var i: usize = 0;
        while (i < n) {
            for (k) in 0..half {
                val u = a[i + k];
                val v = a[i + k + half] * tw[k * step];
                a[i + k] = u + v;
                a[i + k + half] = u - v;
            }
            i += len;
        }
        len *= 2;
    }
}

var x: u64 = 88172645463325252;

fn next() -> u64 {
    x = x ^ (x << 13);
    x = x ^ (x >> 7);
    x = x ^ (x << 17);
    return x;
}

fn unit() -> f64 {
    return @cast<f64>(next() >> 11) / 9007199254740992.0 - 0.5;
}

fn main() -> !void {
    val n = @cast<usize>((std::process::arg(1) ?? "1048576").parse_int() catch 1048576);
    var signal: std::vec<complex> = {};
    try signal.reserve(n);
    for (i) in 0..n {
        val re = unit();
        try signal.push({ re, im: unit() });
    }
    var a_vec: std::vec<complex> = {};
    try a_vec.extend(signal.items());
    var tw_vec: std::vec<complex> = {};
    try tw_vec.resize(n / 2, { re: 0.0, im: 0.0 });
    twiddles(tw_vec.items(), n);
    var inv_vec: std::vec<complex> = {};
    try inv_vec.reserve(n / 2);
    for (w) in tw_vec.items() {
        try inv_vec.push({ re: w.re, im: -w.im });
    }
    val a = a_vec.items();
    val scale = 1.0 / @cast<f64>(n);
    var energy = 0.0;
    var low: complex = { re: 0.0, im: 0.0 };
    var mid: complex = { re: 0.0, im: 0.0 };
    for (round) in 0..16 {
        fft(a, tw_vec.items());
        if (round == 0) {
            for (v) in a {
                energy += v.re * v.re + v.im * v.im;
            }
            low = a[1];
            mid = a[n / 3];
        }
        fft(a, inv_vec.items());
        for (v&) in a {
            *v = *v * scale;
        }
    }
    var err = 0.0;
    var sum = 0.0;
    for (s, k) in signal.items() {
        err = std::math::max(err, std::math::abs(a[k].re - s.re) + std::math::abs(a[k].im - s.im));
        sum += a[k].re + a[k].im;
    }
    if (err > 1e-9) {
        std::eprintln("round trips drifted by {}", err);
        std::process::exit(1);
    }
    std::println("{} points, mean energy {:.6}", n, energy / @cast<f64>(n));
    std::println("X[1] = ({:.6}, {:.6}), X[n/3] = ({:.6}, {:.6})", low.re, low.im, mid.re, mid.im);
    std::println("signal sum after 16 round trips {:.6}", sum);
}
