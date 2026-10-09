// fft: an iterative radix-2 FFT over complex doubles: a random signal of n points (a power of two)
// taken to its spectrum and back sixteen times, then checked against the original; prints the
// spectrum's mean energy and two of its points, and the signal's sum. The twiddles come from
// half-angle formulas (sqrt only, which every language rounds the same) and products, not from sin
// and cos. C++ uses std::complex<double>
#include <cmath>
#include <complex>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <utility>
#include <vector>

using complex = std::complex<double>;

// e^(-2 pi i j / n) for j < n / 2: the table for each len = 2, 4, ... n from the one before, its even
// entries the old ones and its odd ones those times e^(-2 pi i / len)
static std::vector<complex> twiddles(size_t n) {
    std::vector<complex> tw(n / 2);
    tw[0] = 1;
    double c = 0, s = 1; // cos and sin of 2 pi / len
    for (size_t len = 4; len <= n; len *= 2) {
        if (len > 4) {
            c = std::sqrt((1 + c) / 2);
            s = s / (2 * c);
        }
        complex w(c, -s);
        for (size_t j = len / 4; j-- > 0;) {
            tw[2 * j + 1] = tw[j] * w;
            tw[2 * j] = tw[j];
        }
    }
    return tw;
}

static void fft(std::vector<complex> &a, const std::vector<complex> &tw) {
    size_t n = a.size();
    for (size_t i = 1, j = 0; i < n; i++) {
        size_t bit = n >> 1;
        for (; j & bit; bit >>= 1) j ^= bit;
        j ^= bit;
        if (i < j) std::swap(a[i], a[j]);
    }
    for (size_t len = 2; len <= n; len *= 2) {
        size_t half = len / 2, step = n / len;
        for (size_t i = 0; i < n; i += len)
            for (size_t j = 0; j < half; j++) {
                complex u = a[i + j], v = a[i + j + half] * tw[j * step];
                a[i + j] = u + v;
                a[i + j + half] = u - v;
            }
    }
}

static uint64_t x = 88172645463325252ULL;

static uint64_t next() {
    x ^= x << 13;
    x ^= x >> 7;
    x ^= x << 17;
    return x;
}

static double unit() { return double(next() >> 11) / 9007199254740992.0 - 0.5; }

int main(int argc, char **argv) {
    size_t n = argc > 1 ? std::strtoull(argv[1], nullptr, 10) : 1048576;
    std::vector<complex> signal(n);
    for (auto &v : signal) {
        double re = unit();
        v = complex(re, unit());
    }
    std::vector<complex> a = signal, tw = twiddles(n), inv(n / 2);
    for (size_t j = 0; j < n / 2; j++) inv[j] = std::conj(tw[j]);
    double scale = 1.0 / double(n), energy = 0;
    complex low, mid;
    for (int round = 0; round < 16; round++) {
        fft(a, tw);
        if (round == 0) {
            for (const complex &v : a) energy += v.real() * v.real() + v.imag() * v.imag();
            low = a[1];
            mid = a[n / 3];
        }
        fft(a, inv);
        for (complex &v : a) v *= scale;
    }
    double err = 0, sum = 0;
    for (size_t k = 0; k < n; k++) {
        err = std::max(err, std::abs(a[k].real() - signal[k].real()) + std::abs(a[k].imag() - signal[k].imag()));
        sum += a[k].real() + a[k].imag();
    }
    if (err > 1e-9) {
        std::fprintf(stderr, "round trips drifted by %g\n", err);
        return 1;
    }
    std::printf("%zu points, mean energy %.6f\n", n, energy / double(n));
    std::printf("X[1] = (%.6f, %.6f), X[n/3] = (%.6f, %.6f)\n", low.real(), low.imag(), mid.real(), mid.imag());
    std::printf("signal sum after 16 round trips %.6f\n", sum);
}
