// sha256: the SHA-256 digest (FIPS 180-4) of a pseudo-random buffer, a 64-byte block at a time;
// C++ wraps the state in a class of std::arrays, with constexpr round constants and std::rotr
#include <array>
#include <bit>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <span>
#include <string>
#include <vector>

class Sha256 {
    static constexpr std::array<uint32_t, 64> K = {
        0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
        0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
        0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
        0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
        0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
        0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
        0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
        0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
    };
    std::array<uint32_t, 8> h = { 0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a,
                                  0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19 };
    std::array<uint8_t, 64> block{}; // bytes waiting for a whole block
    size_t filled = 0;
    uint64_t total = 0;

    void compress(const uint8_t *b) {
        std::array<uint32_t, 64> w;
        for (int i = 0; i < 16; i++)
            w[i] = uint32_t(b[4 * i]) << 24 | uint32_t(b[4 * i + 1]) << 16 | uint32_t(b[4 * i + 2]) << 8 | b[4 * i + 3];
        for (int i = 16; i < 64; i++) {
            uint32_t s0 = std::rotr(w[i - 15], 7) ^ std::rotr(w[i - 15], 18) ^ (w[i - 15] >> 3);
            uint32_t s1 = std::rotr(w[i - 2], 17) ^ std::rotr(w[i - 2], 19) ^ (w[i - 2] >> 10);
            w[i] = w[i - 16] + s0 + w[i - 7] + s1;
        }
        auto [a, bb, c, d, e, f, g, hh] = h;
        for (int i = 0; i < 64; i++) {
            uint32_t s1 = std::rotr(e, 6) ^ std::rotr(e, 11) ^ std::rotr(e, 25);
            uint32_t ch = (e & f) ^ (~e & g);
            uint32_t t1 = hh + s1 + ch + K[i] + w[i];
            uint32_t s0 = std::rotr(a, 2) ^ std::rotr(a, 13) ^ std::rotr(a, 22);
            uint32_t maj = (a & bb) ^ (a & c) ^ (bb & c);
            uint32_t t2 = s0 + maj;
            hh = g; g = f; f = e; e = d + t1; d = c; c = bb; bb = a; a = t1 + t2;
        }
        h[0] += a; h[1] += bb; h[2] += c; h[3] += d; h[4] += e; h[5] += f; h[6] += g; h[7] += hh;
    }

public:
    void update(std::span<const uint8_t> data) {
        size_t i = 0;
        total += data.size();
        if (filled > 0) {
            while (i < data.size() && filled < 64) block[filled++] = data[i++];
            if (filled < 64) return;
            compress(block.data());
            filled = 0;
        }
        for (; i + 64 <= data.size(); i += 64) compress(&data[i]);
        while (i < data.size()) block[filled++] = data[i++];
    }

    std::array<uint8_t, 32> finish() {
        uint64_t bits = total * 8;
        std::array<uint8_t, 72> tail{ 0x80 };
        size_t n = 64 - (filled + 8) % 64;
        if (n == 0) n = 64;
        for (int k = 0; k < 8; k++) tail[n + k] = uint8_t(bits >> (56 - 8 * k));
        update(std::span(tail).first(n + 8));
        std::array<uint8_t, 32> out;
        for (int i = 0; i < 8; i++) {
            out[4 * i] = uint8_t(h[i] >> 24);
            out[4 * i + 1] = uint8_t(h[i] >> 16);
            out[4 * i + 2] = uint8_t(h[i] >> 8);
            out[4 * i + 3] = uint8_t(h[i]);
        }
        return out;
    }
};

static std::string hex(const std::array<uint8_t, 32> &d) {
    static constexpr char digits[] = "0123456789abcdef";
    std::string s;
    for (uint8_t b : d) { s += digits[b >> 4]; s += digits[b & 15]; }
    return s;
}

static uint64_t x = 88172645463325252ULL;

static uint64_t next() {
    x ^= x << 13;
    x ^= x >> 7;
    x ^= x << 17;
    return x;
}

int main(int argc, char **argv) {
    size_t n = argc > 1 ? size_t(std::atol(argv[1])) : size_t(256) << 20;
    Sha256 abc;
    std::string text = "abc";
    abc.update(std::span(reinterpret_cast<const uint8_t *>(text.data()), text.size()));
    std::string got = hex(abc.finish());
    if (got != "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad") {
        std::fprintf(stderr, "sha256(\"abc\") is wrong: %s\n", got.c_str());
        return 1;
    }
    std::printf("abc %s\n", got.c_str());
    std::vector<uint8_t> buf(n);
    for (auto &b : buf) b = uint8_t(next() >> 56);
    Sha256 s;
    s.update(buf);
    std::printf("%zu %s\n", n, hex(s.finish()).c_str());
}
