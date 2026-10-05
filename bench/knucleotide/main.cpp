// k-nucleotide (the Benchmarks Game): count the k-mers of a long DNA string, k = 1 and 2 as sorted
// frequencies, and five longer ones (up to 18 bases) by building a table for each length; C++ packs
// the bases 2 bits each into a uint64_t key, counted in a std::unordered_map
#include <algorithm>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <string>
#include <string_view>
#include <unordered_map>
#include <utility>
#include <vector>

// every k-mer of codes, its bases 2 bits each
static std::unordered_map<uint64_t, uint32_t> count(const std::vector<uint8_t> &codes, size_t k) {
    std::unordered_map<uint64_t, uint32_t> counts;
    uint64_t mask = (uint64_t(1) << (2 * k)) - 1, key = 0;
    for (size_t i = 0; i < codes.size(); i++) {
        key = ((key << 2) | codes[i]) & mask;
        if (i + 1 >= k) ++counts[key];
    }
    return counts;
}

static uint8_t code_of(char c) {
    switch (c) {
    case 'A': return 0;
    case 'C': return 1;
    case 'G': return 2;
    default: return 3;
    }
}

static void frequencies(const std::vector<uint8_t> &codes, size_t k) {
    auto counts = count(codes, k);
    std::vector<std::pair<uint64_t, uint32_t>> all(counts.begin(), counts.end());
    // most first; ties by key, which for one length is letter order
    std::sort(all.begin(), all.end(), [](const auto &a, const auto &b) {
        return a.second != b.second ? a.second > b.second : a.first < b.first;
    });
    for (auto [key, n] : all) {
        std::string name(k, ' ');
        for (size_t j = 0; j < k; j++) name[j] = "ACGT"[(key >> (2 * (k - 1 - j))) & 3];
        std::printf("%s %.3f\n", name.c_str(), 100.0 * n / (codes.size() - k + 1));
    }
    std::printf("\n");
}

static void occurrences(const std::vector<uint8_t> &codes, std::string_view seq) {
    uint64_t key = 0;
    for (char c : seq) key = (key << 2) | code_of(c);
    auto counts = count(codes, seq.size());
    auto it = counts.find(key);
    std::printf("%u\t%.*s\n", it == counts.end() ? 0u : it->second, int(seq.size()), seq.data());
}

static uint64_t x = 88172645463325252ULL;

static uint64_t next() {
    x ^= x << 13;
    x ^= x >> 7;
    x ^= x << 17;
    return x;
}

int main(int argc, char **argv) {
    size_t n = argc > 1 ? size_t(std::atol(argv[1])) : 25000000;
    // the bases at the human genome's frequencies; the generator that made the original input
    // (fasta) repeats every 139968 numbers, so this sequence repeats with that period too
    const size_t period = 139968;
    std::string dna(n, ' ');
    for (size_t i = 0; i < n; i++) {
        if (i >= period) {
            dna[i] = dna[i - period];
            continue;
        }
        uint64_t r = (next() >> 32) % 1000;
        dna[i] = r < 303 ? 'A' : r < 501 ? 'C' : r < 699 ? 'G' : 'T';
    }
    std::vector<uint8_t> codes(n);
    std::transform(dna.begin(), dna.end(), codes.begin(), code_of);
    frequencies(codes, 1);
    frequencies(codes, 2);
    for (std::string_view seq : { "GGT", "GGTA", "GGTATT", "GGTATTTTAATT", "GGTATTTTAATTTATAGT" })
        occurrences(codes, seq);
}
