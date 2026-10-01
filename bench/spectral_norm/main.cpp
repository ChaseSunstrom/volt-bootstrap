// spectral-norm (the Benchmarks Game): the largest eigenvalue of an infinite matrix, by power iteration
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <vector>

static double a(size_t i, size_t j) { return 1.0 / ((i + j) * (i + j + 1) / 2 + i + 1); }

template <bool T> void times(const std::vector<double> &v, std::vector<double> &out) {
    for (size_t i = 0; i < v.size(); i++) {
        double s = 0;
        for (size_t j = 0; j < v.size(); j++) s += (T ? a(j, i) : a(i, j)) * v[j];
        out[i] = s;
    }
}

int main(int argc, char **argv) {
    size_t n = argc > 1 ? std::atoi(argv[1]) : 5500;
    std::vector<double> u(n, 1.0), v(n), tmp(n);
    for (int k = 0; k < 10; k++) {
        times<false>(u, tmp); times<true>(tmp, v);
        times<false>(v, tmp); times<true>(tmp, u);
    }
    double vbv = 0, vv = 0;
    for (size_t i = 0; i < n; i++) { vbv += u[i] * v[i]; vv += v[i] * v[i]; }
    std::printf("%.9f\n", std::sqrt(vbv / vv));
}
