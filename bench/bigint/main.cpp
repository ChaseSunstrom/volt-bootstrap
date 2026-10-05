// bigint: arbitrary-precision integers in base 1e9 limbs: n! by repeated small multiplies, the m-th
// Fibonacci number by repeated additions, and a schoolbook product of two big numbers, each printed
// as its digit count and digit sum; C++ wraps a std::vector<uint32_t> in a class with operators
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <vector>

constexpr uint32_t BASE = 1000000000u;

class big {
public:
    std::vector<uint32_t> limbs; // least significant first
    explicit big(uint32_t v) : limbs{v} {}
    big() = default;

    big &operator*=(uint32_t k) {
        uint64_t carry = 0;
        for (auto &l : limbs) {
            uint64_t x = uint64_t(l) * k + carry;
            l = uint32_t(x % BASE);
            carry = x / BASE;
        }
        while (carry) {
            limbs.push_back(uint32_t(carry % BASE));
            carry /= BASE;
        }
        return *this;
    }

    big operator+(const big &o) const {
        const big &l = limbs.size() >= o.limbs.size() ? *this : o, &s = limbs.size() >= o.limbs.size() ? o : *this;
        big r;
        r.limbs.resize(l.limbs.size());
        uint32_t carry = 0;
        for (size_t i = 0; i < l.limbs.size(); i++) {
            uint32_t x = l.limbs[i] + (i < s.limbs.size() ? s.limbs[i] : 0) + carry;
            carry = x >= BASE;
            r.limbs[i] = carry ? x - BASE : x;
        }
        if (carry) r.limbs.push_back(1);
        return r;
    }

    big operator*(const big &o) const {
        big r;
        r.limbs.assign(limbs.size() + o.limbs.size(), 0);
        for (size_t i = 0; i < limbs.size(); i++) {
            uint64_t carry = 0;
            for (size_t j = 0; j < o.limbs.size(); j++) {
                uint64_t x = r.limbs[i + j] + uint64_t(limbs[i]) * o.limbs[j] + carry;
                r.limbs[i + j] = uint32_t(x % BASE);
                carry = x / BASE;
            }
            r.limbs[i + o.limbs.size()] = uint32_t(carry);
        }
        while (r.limbs.size() > 1 && r.limbs.back() == 0) r.limbs.pop_back();
        return r;
    }
};

static void report(const char *what, const big &b) {
    uint64_t sum = 0;
    for (auto l : b.limbs)
        for (uint32_t x = l; x; x /= 10) sum += x % 10;
    size_t digits = (b.limbs.size() - 1) * 9;
    for (uint32_t top = b.limbs.back(); top; top /= 10) digits++;
    std::printf("%s: %zu digits, digit sum %llu\n", what, digits, (unsigned long long)sum);
}

int main(int argc, char **argv) {
    uint32_t n = argc > 1 ? uint32_t(std::strtoul(argv[1], nullptr, 10)) : 20000;
    big f(1);
    for (uint32_t k = 2; k <= n; k++) f *= k;
    report("factorial", f);
    // fib[i % 2] steps through the Fibonacci numbers, each sum replacing the older of the two
    big fib[2] = {big(0), big(1)};
    for (uint32_t i = 0; i < n * 10; i++) fib[i % 2] = fib[0] + fib[1];
    report("fibonacci", fib[1]);
    report("product", f * fib[1]);
}
