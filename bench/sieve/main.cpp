// sieve: the primes below n with the sieve of Eratosthenes over a byte array
#include <cstdio>
#include <cstdlib>
#include <vector>

int main(int argc, char **argv) {
    long n = argc > 1 ? std::atol(argv[1]) : 200000000;
    std::vector<unsigned char> prime(n, 1);
    prime[0] = prime[1] = 0;
    for (long i = 2; i * i < n; i++)
        if (prime[i])
            for (long j = i * i; j < n; j += i) prime[j] = 0;
    long count = 0, last = 0;
    for (long i = 0; i < n; i++)
        if (prime[i]) {
            count++;
            last = i;
        }
    std::printf("%ld %ld\n", count, last);
}
