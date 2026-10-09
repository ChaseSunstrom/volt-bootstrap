// revcomp (the Benchmarks Game): the reverse complement of a 64 MiB DNA sequence in FASTA lines of
// 60 bases, done nine times between two byte buffers; prints the size, the first line and an FNV-1a
// checksum of the result
#include <array>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <string_view>
#include <utility>
#include <vector>

static uint64_t x = 88172645463325252ULL;

static uint64_t next() {
    x ^= x << 13;
    x ^= x >> 7;
    x ^= x << 17;
    return x;
}

// out gets in's bases from last to first, each complemented, 60 a line
static void revcomp(const std::vector<unsigned char> &in, std::vector<unsigned char> &out, const std::array<unsigned char, 256> &comp) {
    size_t o = 0, col = 0;
    for (auto it = in.rbegin(); it != in.rend(); ++it) {
        if (*it == '\n') continue;
        out[o++] = comp[*it];
        if (++col == 60) {
            out[o++] = '\n';
            col = 0;
        }
    }
    if (col > 0) out[o++] = '\n';
}

int main(int argc, char **argv) {
    size_t n = argc > 1 ? std::strtoull(argv[1], nullptr, 10) : 67108864;
    // each IUPAC code and its complement, upper and lower case
    constexpr std::string_view from = "ACGTUMRWSYKVHDBNacgtumrwsykvhdbn", to = "TGCAAKYWSRMBDHVNTGCAAKYWSRMBDHVN";
    std::array<unsigned char, 256> comp;
    for (int i = 0; i < 256; i++) comp[i] = (unsigned char)i;
    for (size_t i = 0; i < from.size(); i++) comp[(unsigned char)from[i]] = (unsigned char)to[i];
    // the bases: mostly ACGT, some lower case and other codes
    constexpr std::string_view alphabet = "ACGTACGTACGTacgtNRYKMSWBDHVnACGT";
    std::vector<unsigned char> a, b(n + (n + 59) / 60);
    a.reserve(b.size());
    for (size_t i = 0; i < n; i++) {
        a.push_back((unsigned char)alphabet[next() >> 59]);
        if (i % 60 == 59 || i == n - 1) a.push_back('\n');
    }
    for (int pass = 0; pass < 9; pass++) {
        revcomp(a, b, comp);
        std::swap(a, b);
    }
    uint64_t check = 14695981039346656037ULL;
    for (unsigned char c : a) check = (check ^ c) * 1099511628211ULL;
    size_t first = a.size() < 60 ? a.size() - 1 : 60;
    std::printf("%zu bases, %zu bytes\n%.*s\n%llu\n", n, a.size(), (int)first, (const char *)a.data(), (unsigned long long)check);
}
