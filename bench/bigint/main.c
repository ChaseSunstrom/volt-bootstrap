// bigint: arbitrary-precision integers in base 1e9 limbs: n! by repeated small multiplies, the m-th
// Fibonacci number by repeated additions, and a schoolbook product of two big numbers, each printed
// as its digit count and digit sum; C keeps the limbs in a malloc'd array with functions over it
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define BASE 1000000000u

typedef struct {
    uint32_t *limbs; // least significant first
    size_t len, cap;
} big;

static void reserve(big *b, size_t n) {
    if (n > b->cap) {
        b->cap = n * 2;
        b->limbs = realloc(b->limbs, b->cap * sizeof(uint32_t));
    }
}

static big from(uint32_t v) {
    big b = {0, 0, 0};
    reserve(&b, 1);
    b.limbs[0] = v;
    b.len = 1;
    return b;
}

static void mul_small(big *b, uint32_t k) {
    uint64_t carry = 0;
    for (size_t i = 0; i < b->len; i++) {
        uint64_t x = (uint64_t)b->limbs[i] * k + carry;
        b->limbs[i] = (uint32_t)(x % BASE);
        carry = x / BASE;
    }
    while (carry) {
        reserve(b, b->len + 1);
        b->limbs[b->len++] = (uint32_t)(carry % BASE);
        carry /= BASE;
    }
}

static big add(const big *a, const big *b) {
    const big *l = a->len >= b->len ? a : b, *s = a->len >= b->len ? b : a;
    big r = {0, 0, 0};
    reserve(&r, l->len + 1);
    uint32_t carry = 0;
    for (size_t i = 0; i < l->len; i++) {
        uint32_t x = l->limbs[i] + (i < s->len ? s->limbs[i] : 0) + carry;
        carry = x >= BASE;
        r.limbs[i] = carry ? x - BASE : x;
    }
    r.len = l->len;
    if (carry) r.limbs[r.len++] = 1;
    return r;
}

static big mul(const big *a, const big *b) {
    big r = {0, 0, 0};
    reserve(&r, a->len + b->len);
    memset(r.limbs, 0, (a->len + b->len) * sizeof(uint32_t));
    for (size_t i = 0; i < a->len; i++) {
        uint64_t carry = 0;
        for (size_t j = 0; j < b->len; j++) {
            uint64_t x = r.limbs[i + j] + (uint64_t)a->limbs[i] * b->limbs[j] + carry;
            r.limbs[i + j] = (uint32_t)(x % BASE);
            carry = x / BASE;
        }
        r.limbs[i + b->len] = (uint32_t)carry;
    }
    r.len = a->len + b->len;
    while (r.len > 1 && r.limbs[r.len - 1] == 0) r.len--;
    return r;
}

// digit count and digit sum
static void report(const char *what, const big *b) {
    uint64_t sum = 0;
    for (size_t i = 0; i < b->len; i++)
        for (uint32_t x = b->limbs[i]; x; x /= 10) sum += x % 10;
    size_t digits = (b->len - 1) * 9;
    for (uint32_t top = b->limbs[b->len - 1]; top; top /= 10) digits++;
    printf("%s: %zu digits, digit sum %llu\n", what, digits, (unsigned long long)sum);
}

int main(int argc, char **argv) {
    uint32_t n = argc > 1 ? (uint32_t)strtoul(argv[1], 0, 10) : 20000;
    big f = from(1);
    for (uint32_t k = 2; k <= n; k++) mul_small(&f, k);
    report("factorial", &f);
    // fib[i % 2] steps through the Fibonacci numbers, each sum replacing the older of the two
    big fib[2] = {from(0), from(1)};
    for (uint32_t i = 0; i < n * 10; i++) {
        big sum = add(&fib[0], &fib[1]);
        free(fib[i % 2].limbs);
        fib[i % 2] = sum;
    }
    report("fibonacci", &fib[1]);
    big p = mul(&f, &fib[1]);
    report("product", &p);
    free(f.limbs);
    free(fib[0].limbs);
    free(fib[1].limbs);
    free(p.limbs);
    return 0;
}
