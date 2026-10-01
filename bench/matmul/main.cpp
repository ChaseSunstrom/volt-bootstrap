// matmul: two n×n matrices of doubles multiplied in i, k, j order (row by row, cache-friendly)
#include <cstdio>
#include <cstdlib>
#include <vector>

int main(int argc, char **argv) {
    int n = argc > 1 ? std::atoi(argv[1]) : 1600;
    std::vector<double> a(n * n), b(n * n), c(n * n, 0.0);
    for (int i = 0; i < n; i++)
        for (int j = 0; j < n; j++) {
            a[i * n + j] = double(i - j) / n;
            b[i * n + j] = double(i + 2 * j + 1) / n;
        }
    for (int i = 0; i < n; i++)
        for (int k = 0; k < n; k++) {
            double aik = a[i * n + k];
            for (int j = 0; j < n; j++) c[i * n + j] += aik * b[k * n + j];
        }
    double trace = 0, sum = 0;
    for (int i = 0; i < n; i++) trace += c[i * n + i];
    for (double x : c) sum += x;
    std::printf("%.6f %.6f\n", trace, sum);
}
