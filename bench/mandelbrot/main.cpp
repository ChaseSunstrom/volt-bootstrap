// mandelbrot (after the Benchmarks Game): how many points of an n x n grid stay in the set for 50 steps
#include <complex>
#include <cstdio>
#include <cstdlib>

int main(int argc, char **argv) {
    int n = argc > 1 ? std::atoi(argv[1]) : 4000;
    long inside = 0;
    for (int y = 0; y < n; y++) {
        double ci = 2.0 * y / n - 1.0;
        for (int x = 0; x < n; x++) {
            double cr = 2.0 * x / n - 1.5, zr = 0, zi = 0, tr = 0, ti = 0;
            for (int i = 0; i < 50 && tr + ti <= 4.0; i++) { zi = 2.0 * zr * zi + ci; zr = tr - ti + cr; tr = zr * zr; ti = zi * zi; }
            inside += tr + ti <= 4.0;
        }
    }
    std::printf("%ld\n", inside);
}
