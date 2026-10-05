// wordfreq: count the words of a text of n words drawn from a Zipf-like vocabulary in a hash map keyed
// by string, then print the 20 most frequent; C++ uses std::unordered_map<std::string, long> and
// std::sort with a lambda
#include <algorithm>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <string>
#include <string_view>
#include <unordered_map>
#include <vector>

static uint64_t x = 88172645463325252ULL;

static uint64_t next() {
    x ^= x << 13;
    x ^= x >> 7;
    x ^= x << 17;
    return x;
}

int main(int argc, char **argv) {
    long n = argc > 1 ? std::atol(argv[1]) : 20000000;
    // the vocabulary: random lowercase words of 3 to 10 letters
    std::vector<std::string> words(1 << 18);
    for (auto &w : words) {
        size_t len = 3 + next() % 8;
        for (size_t j = 0; j < len; j++) w += char('a' + next() % 26);
    }
    // the text: word k is picked about 1/k as often as word 1
    std::string text;
    for (long i = 0; i < n; i++) {
        uint64_t bits = next() % 19;
        uint64_t k = next() & ((1ULL << bits) - 1);
        text += words[k];
        text += ' ';
    }
    std::unordered_map<std::string, long> counts;
    std::string_view all = text;
    size_t start = 0;
    long total = 0;
    for (size_t i = 0; i < all.size(); i++) {
        if (all[i] == ' ') {
            counts[std::string(all.substr(start, i - start))]++;
            total++;
            start = i + 1;
        }
    }
    std::vector<std::pair<std::string, long>> ranked(counts.begin(), counts.end());
    std::sort(ranked.begin(), ranked.end(), [](const auto &a, const auto &b) {
        return a.second != b.second ? a.second > b.second : a.first < b.first;
    });
    std::printf("%zu bytes, %ld words, %zu distinct\n", text.size(), total, ranked.size());
    for (size_t i = 0; i < 20 && i < ranked.size(); i++) std::printf("%s %ld\n", ranked[i].first.c_str(), ranked[i].second);
}
