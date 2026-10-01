// strings: build a long text of numbered words, split it on spaces, count and join the long words
#include <cstdio>
#include <cstdlib>
#include <string>
#include <string_view>
#include <vector>

int main(int argc, char **argv) {
    long n = argc > 1 ? std::atol(argv[1]) : 10000000;
    std::string text;
    for (long i = 0; i < n; i++) { text += "word"; text += std::to_string(i * 7 % 1000003); text += ' '; }
    std::vector<std::string_view> words;
    std::string_view all = text;
    size_t start = 0;
    for (size_t i = 0; i < all.size(); i++)
        if (all[i] == ' ') { words.push_back(all.substr(start, i - start)); start = i + 1; }
    std::string joined;
    long long_words = 0;
    for (auto w : words)
        if (w.size() > 9) { if (long_words++) joined += ','; joined += w; }
    std::printf("%zu %zu %ld %zu\n", text.size(), words.size(), long_words, joined.size());
}
