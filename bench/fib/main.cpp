// fib: the naive doubly recursive Fibonacci, which is all function calls
#include <cstdio>
#include <cstdlib>

static long fib(int n) { return n < 2 ? n : fib(n - 1) + fib(n - 2); }

int main(int argc, char **argv) {
    int n = argc > 1 ? std::atoi(argv[1]) : 42;
    std::printf("%ld\n", fib(n));
}
