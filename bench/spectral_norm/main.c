// spectral-norm (the Benchmarks Game): the largest eigenvalue of an infinite matrix, by power iteration
#include <math.h>
#include <stdio.h>
#include <stdlib.h>

static double a(int i, int j) { return 1.0 / ((i + j) * (i + j + 1) / 2 + i + 1); }

static void times(const double *v, double *out, int n) {
    for (int i = 0; i < n; i++) { double s = 0; for (int j = 0; j < n; j++) s += a(i, j) * v[j]; out[i] = s; }
}
static void times_t(const double *v, double *out, int n) {
    for (int i = 0; i < n; i++) { double s = 0; for (int j = 0; j < n; j++) s += a(j, i) * v[j]; out[i] = s; }
}
static void ata(const double *v, double *out, double *tmp, int n) { times(v, tmp, n); times_t(tmp, out, n); }

int main(int argc, char **argv) {
    int n = argc > 1 ? atoi(argv[1]) : 5500;
    double *u = malloc(n * sizeof(double)), *v = malloc(n * sizeof(double)), *tmp = malloc(n * sizeof(double));
    for (int i = 0; i < n; i++) u[i] = 1;
    for (int k = 0; k < 10; k++) { ata(u, v, tmp, n); ata(v, u, tmp, n); }
    double vbv = 0, vv = 0;
    for (int i = 0; i < n; i++) { vbv += u[i] * v[i]; vv += v[i] * v[i]; }
    printf("%.9f\n", sqrt(vbv / vv));
    free(u); free(v); free(tmp);
    return 0;
}
