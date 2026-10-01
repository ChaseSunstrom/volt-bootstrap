// matmul: two n×n matrices of doubles multiplied in i, k, j order (row by row, cache-friendly)
#include <stdio.h>
#include <stdlib.h>

int main(int argc, char **argv) {
    int n = argc > 1 ? atoi(argv[1]) : 1600;
    double *a = malloc(sizeof(double) * n * n), *b = malloc(sizeof(double) * n * n), *c = calloc((size_t)n * n, sizeof(double));
    for (int i = 0; i < n; i++)
        for (int j = 0; j < n; j++) {
            a[i * n + j] = (double)(i - j) / n;
            b[i * n + j] = (double)(i + 2 * j + 1) / n;
        }
    for (int i = 0; i < n; i++)
        for (int k = 0; k < n; k++) {
            double aik = a[i * n + k];
            for (int j = 0; j < n; j++) c[i * n + j] += aik * b[k * n + j];
        }
    double trace = 0, sum = 0;
    for (int i = 0; i < n; i++) trace += c[i * n + i];
    for (int i = 0; i < n * n; i++) sum += c[i];
    printf("%.6f %.6f\n", trace, sum);
    free(a);
    free(b);
    free(c);
    return 0;
}
