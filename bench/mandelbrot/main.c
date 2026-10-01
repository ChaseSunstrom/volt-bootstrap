// mandelbrot (after the Benchmarks Game): how many points of an n x n grid stay in the set for 50 steps
#include <stdio.h>
#include <stdlib.h>

int main(int argc, char **argv) {
    int n = argc > 1 ? atoi(argv[1]) : 4000;
    long inside = 0;
    for (int y = 0; y < n; y++) {
        double ci = 2.0 * y / n - 1.0;
        for (int x = 0; x < n; x++) {
            double cr = 2.0 * x / n - 1.5, zr = 0, zi = 0, tr = 0, ti = 0;
            int i = 0;
            while (i < 50 && tr + ti <= 4.0) {
                zi = 2.0 * zr * zi + ci;
                zr = tr - ti + cr;
                tr = zr * zr;
                ti = zi * zi;
                i++;
            }
            if (tr + ti <= 4.0) inside++;
        }
    }
    printf("%ld\n", inside);
    return 0;
}
