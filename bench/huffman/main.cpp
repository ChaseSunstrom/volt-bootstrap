// huffman: Huffman-code a skewed 64-letter text: count the letters, build the code tree from a
// priority queue of (weight, node), write every letter's code as bits, then read the bits back a bit
// at a time down the tree and check the round trip; C++ uses std::priority_queue and std::optional
// children
#include <algorithm>
#include <array>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <functional>
#include <optional>
#include <queue>
#include <string_view>
#include <utility>
#include <vector>

struct node {
    uint64_t weight;
    std::optional<int> left, right; // none on a leaf
    unsigned char sym;
};

static void assign(const std::vector<node> &nodes, int id, uint64_t code, int len, std::array<uint64_t, 256> &codes, std::array<int, 256> &lens) {
    const node &nd = nodes[id];
    if (!nd.left) {
        codes[nd.sym] = code;
        lens[nd.sym] = len;
        return;
    }
    assign(nodes, *nd.left, code << 1, len + 1, codes, lens);
    assign(nodes, *nd.right, (code << 1) | 1, len + 1, codes, lens);
}

static uint64_t fnv(const std::vector<unsigned char> &s) {
    uint64_t h = 14695981039346656037ULL;
    for (unsigned char c : s) h = (h ^ c) * 1099511628211ULL;
    return h;
}

static uint64_t x = 88172645463325252ULL;

static uint64_t next() {
    x ^= x << 13;
    x ^= x >> 7;
    x ^= x << 17;
    return x;
}

int main(int argc, char **argv) {
    size_t n = argc > 1 ? std::strtoull(argv[1], nullptr, 10) : 33554432;
    // the text: letters of a 64-letter alphabet, the first ones the most common
    constexpr std::string_view alphabet = "etaoinshrdlcumwfgypbvkjxqzETAOINSHRDLCUMWFGYPBVKJXQZ0123456789 .";
    std::vector<unsigned char> text(n);
    for (auto &c : text) {
        uint64_t r = next();
        c = (unsigned char)alphabet[((r >> 8) % 64) * ((r >> 20) % 64) / 63];
    }
    std::array<uint64_t, 256> count{};
    for (unsigned char c : text) count[c]++;
    // a leaf per letter that occurs, in byte order; then a node joining the two lightest, until one is left
    std::vector<node> nodes;
    std::priority_queue<std::pair<uint64_t, int>, std::vector<std::pair<uint64_t, int>>, std::greater<>> queue;
    for (int c = 0; c < 256; c++)
        if (count[c] > 0) {
            queue.push({ count[c], (int)nodes.size() });
            nodes.push_back({ count[c], std::nullopt, std::nullopt, (unsigned char)c });
        }
    size_t symbols = nodes.size();
    while (queue.size() > 1) {
        auto a = queue.top();
        queue.pop();
        auto b = queue.top();
        queue.pop();
        queue.push({ a.first + b.first, (int)nodes.size() });
        nodes.push_back({ a.first + b.first, a.second, b.second, 0 });
    }
    int root = queue.top().second;
    std::array<uint64_t, 256> codes{};
    std::array<int, 256> lens{};
    assign(nodes, root, 0, 0, codes, lens);
    int longest = 0;
    for (int l : lens) longest = std::max(longest, l);
    // write the codes, the first bit of each byte the highest
    std::vector<unsigned char> packed;
    packed.reserve(n * longest / 8 + 1);
    uint64_t acc = 0;
    int bits = 0;
    for (unsigned char c : text) {
        acc = (acc << lens[c]) | codes[c];
        bits += lens[c];
        while (bits >= 8) {
            bits -= 8;
            packed.push_back((unsigned char)(acc >> bits));
        }
    }
    if (bits > 0) packed.push_back((unsigned char)(acc << (8 - bits)));
    // read them back down the tree
    std::vector<unsigned char> back(n);
    size_t pos = 0;
    for (auto &c : back) {
        const node *nd = &nodes[root];
        while (nd->left) {
            int bit = (packed[pos >> 3] >> (7 - (pos & 7))) & 1;
            pos++;
            nd = &nodes[bit ? *nd->right : *nd->left];
        }
        c = nd->sym;
    }
    if (back != text) {
        std::fprintf(stderr, "round trip failed\n");
        return 1;
    }
    std::printf("%zu letters, %zu symbols, longest code %d bits\n", n, symbols, longest);
    std::printf("packed %zu bytes, checksum %llu\n", packed.size(), (unsigned long long)fnv(packed));
    std::printf("unpacked %zu bytes, checksum %llu\n", n, (unsigned long long)fnv(back));
}
