// fft: an iterative radix-2 FFT over complex doubles: a random signal of n points (a power of two)
// taken to its spectrum and back sixteen times, then checked against the original; prints the
// spectrum's mean energy and two of its points, and the signal's sum. The twiddles come from
// half-angle formulas (sqrt only, which every language rounds the same) and products, not from sin
// and cos. C has a struct and functions for the arithmetic
#include <math.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>

typedef struct { double re, im; } complex;

static inline complex add(complex a, complex b) { return (complex){ a.re + b.re, a.im + b.im }; }
static inline complex sub(complex a, complex b) { return (complex){ a.re - b.re, a.im - b.im }; }
static inline complex mul(complex a, complex b) { return (complex){ a.re * b.re - a.im * b.im, a.re * b.im + a.im * b.re }; }

// tw[j] = e^(-2 pi i j / n) for j < n / 2, and inv the conjugates: the table for each len = 2, 4,
// ... n from the one before, its even entries the old ones and its odd ones those times
// e^(-2 pi i / len)
static void twiddles(complex *tw, complex *inv, size_t n) {
    tw[0] = (complex){ 1, 0 };
    double c = 0, s = 1; // cos and sin of 2 pi / len
    for (size_t len = 4; len <= n; len *= 2) {
        if (len > 4) {
            c = sqrt((1 + c) / 2);
            s = s / (2 * c);
        }
        complex w = { c, -s };
        for (size_t j = len / 4; j-- > 0;) {
            tw[2 * j + 1] = mul(tw[j], w);
            tw[2 * j] = tw[j];
        }
    }
    for (size_t j = 0; j < n / 2; j++) inv[j] = (complex){ tw[j].re, -tw[j].im };
}

static void fft(complex *a, size_t n, const complex *tw) {
    for (size_t i = 1, j = 0; i < n; i++) {
        size_t bit = n >> 1;
        for (; j & bit; bit >>= 1) j ^= bit;
        j ^= bit;
        if (i < j) {
            complex t = a[i];
            a[i] = a[j];
            a[j] = t;
        }
    }
    for (size_t len = 2; len <= n; len *= 2) {
        size_t half = len / 2, step = n / len;
        for (size_t i = 0; i < n; i += len)
            for (size_t j = 0; j < half; j++) {
                complex u = a[i + j], v = mul(a[i + j + half], tw[j * step]);
                a[i + j] = add(u, v);
                a[i + j + half] = sub(u, v);
            }
    }
}

static uint64_t x = 88172645463325252ULL;

static uint64_t next(void) {
    x ^= x << 13;
    x ^= x >> 7;
    x ^= x << 17;
    return x;
}

static double unit(void) { return (double)(next() >> 11) / 9007199254740992.0 - 0.5; }

int main(int argc, char **argv) {
    size_t n = argc > 1 ? (size_t)atol(argv[1]) : 1048576;
    complex *signal = malloc(n * sizeof(complex)), *a = malloc(n * sizeof(complex));
    complex *tw = malloc(n / 2 * sizeof(complex)), *inv = malloc(n / 2 * sizeof(complex));
    for (size_t i = 0; i < n; i++) {
        double re = unit();
        signal[i] = (complex){ re, unit() };
        a[i] = signal[i];
    }
    twiddles(tw, inv, n);
    double scale = 1.0 / (double)n;
    double energy = 0;
    complex low = { 0, 0 }, mid = { 0, 0 };
    for (int round = 0; round < 16; round++) {
        fft(a, n, tw);
        if (round == 0) {
            for (size_t k = 0; k < n; k++) energy += a[k].re * a[k].re + a[k].im * a[k].im;
            low = a[1];
            mid = a[n / 3];
        }
        fft(a, n, inv);
        for (size_t k = 0; k < n; k++) a[k] = (complex){ a[k].re * scale, a[k].im * scale };
    }
    double err = 0, sum = 0;
    for (size_t k = 0; k < n; k++) {
        double d = fabs(a[k].re - signal[k].re) + fabs(a[k].im - signal[k].im);
        if (d > err) err = d;
        sum += a[k].re + a[k].im;
    }
    if (err > 1e-9) {
        fprintf(stderr, "round trips drifted by %g\n", err);
        return 1;
    }
    printf("%zu points, mean energy %.6f\n", n, energy / (double)n);
    printf("X[1] = (%.6f, %.6f), X[n/3] = (%.6f, %.6f)\n", low.re, low.im, mid.re, mid.im);
    printf("signal sum after 16 round trips %.6f\n", sum);
    free(signal);
    free(a);
    free(tw);
    free(inv);
    return 0;
}
