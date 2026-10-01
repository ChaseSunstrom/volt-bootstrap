// fib: the naive doubly recursive Fibonacci, which is all function calls
#include <stdio.h>
#include <stdlib.h>

static long fib(int n) { return n < 2 ? n : fib(n - 1) + fib(n - 2); }

int main(int argc, char **argv) {
    int n = argc > 1 ? atoi(argv[1]) : 42;
    printf("%ld\n", fib(n));
    return 0;
}
