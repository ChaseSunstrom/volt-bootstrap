// levenshtein: edit distances between many pairs of strings, each a random string of 64 to 191
// letters and a copy with random substitutions, deletions and insertions, by the dynamic program
// over one row; prints the number of pairs, the sum and the largest of the distances, and a checksum
// of them all
#include <algorithm>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <string>
#include <string_view>
#include <vector>

static uint64_t x = 88172645463325252ULL;

static uint64_t next() {
    x ^= x << 13;
    x ^= x >> 7;
    x ^= x << 17;
    return x;
}

static uint32_t distance(std::string_view a, std::string_view b, std::vector<uint32_t> &row) {
    row.resize(b.size() + 1);
    for (size_t j = 0; j <= b.size(); j++) row[j] = (uint32_t)j;
    for (size_t i = 1; i <= a.size(); i++) {
        uint32_t diag = row[0];
        row[0] = (uint32_t)i;
        for (size_t j = 1; j <= b.size(); j++) {
            uint32_t up = row[j];
            row[j] = std::min({ diag + (a[i - 1] != b[j - 1]), up + 1, row[j - 1] + 1 });
            diag = up;
        }
    }
    return row[b.size()];
}

int main(int argc, char **argv) {
    size_t pairs = argc > 1 ? std::strtoull(argv[1], nullptr, 10) : 40000;
    constexpr std::string_view letters = "abcdefgh";
    std::string a, b;
    std::vector<uint32_t> row;
    uint64_t total = 0, check = 0;
    uint32_t most = 0;
    for (size_t p = 0; p < pairs; p++) {
        size_t la = 64 + next() % 128;
        a.clear();
        for (size_t i = 0; i < la; i++) a.push_back(letters[next() % 8]);
        // b: a with about one letter in 8 changed, one in 16 dropped and one in 16 inserted
        b.clear();
        for (char c : a) {
            uint64_t r = next() % 16;
            if (r == 0) continue;
            if (r == 1) b.push_back(letters[next() % 8]);
            b.push_back(r == 2 || r == 3 ? letters[next() % 8] : c);
        }
        uint32_t d = distance(a, b, row);
        total += d;
        most = std::max(most, d);
        check = check * 31 + d;
    }
    std::printf("%zu pairs, total distance %llu, largest %u\n", pairs, (unsigned long long)total, most);
    std::printf("checksum %llu\n", (unsigned long long)check);
}
