// fasta (the Benchmarks Game): generate three DNA sequences, n*2 bases repeating the ALU string, then
// n*3 and n*5 bases drawn by a linear congruential generator from cumulative probability tables, in
// FASTA lines of 60; prints each one's header, length and an FNV-1a checksum of its lines in place of
// the text. C++ builds the cumulative tables in a constexpr function
#include <array>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <string_view>

struct acid {
    char c;
    double p;
};

constexpr std::string_view ALU = "GGCCGGGCGCGGTGGCTCACGCCTGTAATCCCAGCACTTTGGGAGGCCGAGGCGGGCGGATCACCTGAGGTCAGGAGTTCGAGACCAGCC"
                                 "TGGCCAACATGGTGAAACCCCGTCTCTACTAAAAATACAAAAATTAGCCGGGCGTGGTGGCGCGCGCCTGTAATCCCAGCTACTCGGGAG"
                                 "GCTGAGGCAGGAGAATCGCTTGAACCCGGGAGGCGGAGGTTGCAGTGAGCCGAGATCGCGCCACTGCACTCCAGCCTGGGCGACAGAGCGA"
                                 "GACTCCGTCTCAAAAA";

// each p becomes the sum of the ones up to it
template <size_t N> constexpr std::array<acid, N> cumulative(std::array<acid, N> t) {
    double sum = 0;
    for (auto &a : t) {
        sum += a.p;
        a.p = sum;
    }
    return t;
}

constexpr auto IUB = cumulative<15>({ { { 'a', 0.27 }, { 'c', 0.12 }, { 'g', 0.12 }, { 't', 0.27 }, { 'B', 0.02 }, { 'D', 0.02 }, { 'H', 0.02 }, { 'K', 0.02 }, { 'M', 0.02 }, { 'N', 0.02 }, { 'R', 0.02 }, { 'S', 0.02 }, { 'V', 0.02 }, { 'W', 0.02 }, { 'Y', 0.02 } } });

constexpr auto HOMO_SAPIENS = cumulative<4>({ { { 'a', 0.3029549426680 }, { 'c', 0.1979883004921 }, { 'g', 0.1975473066391 }, { 't', 0.3015094502008 } } });

constexpr uint32_t IM = 139968, IA = 3877, IC = 29573;

static uint32_t seed = 42;

static double random_unit() {
    seed = (seed * IA + IC) % IM;
    return double(seed) / IM;
}

static uint64_t fnv(uint64_t h, std::string_view s) {
    for (unsigned char c : s) h = (h ^ c) * 1099511628211ULL;
    return h;
}

static void repeat(const char *header, std::string_view s, size_t n) {
    size_t pos = 0;
    char line[61];
    uint64_t h = 14695981039346656037ULL;
    for (size_t done = 0; done < n;) {
        size_t m = n - done < 60 ? n - done : 60;
        for (size_t i = 0; i < m; i++) {
            line[i] = s[pos];
            if (++pos == s.size()) pos = 0;
        }
        line[m] = '\n';
        h = fnv(h, std::string_view(line, m + 1));
        done += m;
    }
    std::printf("%s: %zu bases, checksum %llu\n", header, n, (unsigned long long)h);
}

template <size_t N> static void random_bases(const char *header, const std::array<acid, N> &t, size_t n) {
    char line[61];
    uint64_t h = 14695981039346656037ULL;
    for (size_t done = 0; done < n;) {
        size_t m = n - done < 60 ? n - done : 60;
        for (size_t i = 0; i < m; i++) {
            double r = random_unit();
            size_t k = 0;
            while (k < N - 1 && r >= t[k].p) k++;
            line[i] = t[k].c;
        }
        line[m] = '\n';
        h = fnv(h, std::string_view(line, m + 1));
        done += m;
    }
    std::printf("%s: %zu bases, checksum %llu\n", header, n, (unsigned long long)h);
}

int main(int argc, char **argv) {
    size_t n = argc > 1 ? std::strtoull(argv[1], nullptr, 10) : 10000000;
    repeat(">ONE Homo sapiens alu", ALU, n * 2);
    random_bases(">TWO IUB ambiguity codes", IUB, n * 3);
    random_bases(">THREE Homo sapiens frequency", HOMO_SAPIENS, n * 5);
}
