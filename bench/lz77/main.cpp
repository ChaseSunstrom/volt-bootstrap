// lz77: compress a repetitive text with LZ77 (a hash table of recent positions, chains of at most 8
// probes, a 64 KiB window), decompress it and check the round trip; C++ builds std::vectors from
// std::spans, and the decoder throws on corrupt input
#include <algorithm>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <span>
#include <stdexcept>
#include <string>
#include <vector>

// the format: a byte c < 128 is followed by c + 1 literal bytes; c >= 128 is a match of
// c - 128 + MIN_MATCH bytes, then its distance back (1..MAX_DIST) in two bytes, low first
constexpr int HASH_BITS = 16;
constexpr size_t WINDOW = 1 << 16, MIN_MATCH = 4, MAX_MATCH = MIN_MATCH + 127, MAX_DIST = WINDOW - 1;
constexpr int MAX_CHAIN = 8;

static uint32_t hash4(const uint8_t *p) {
    uint32_t v = uint32_t(p[0]) | uint32_t(p[1]) << 8 | uint32_t(p[2]) << 16 | uint32_t(p[3]) << 24;
    return (v * 2654435761u) >> (32 - HASH_BITS);
}

static std::vector<uint8_t> compress(std::span<const uint8_t> in) {
    std::vector<int32_t> head(size_t(1) << HASH_BITS, -1), prev(WINDOW);
    std::vector<uint8_t> out;
    auto put_literals = [&](size_t from, size_t to) {
        while (from < to) {
            size_t k = std::min<size_t>(to - from, 128);
            out.push_back(uint8_t(k - 1));
            out.insert(out.end(), in.begin() + from, in.begin() + from + k);
            from += k;
        }
    };
    size_t n = in.size(), i = 0, lit = 0;
    while (i + MIN_MATCH <= n) {
        uint32_t h = hash4(&in[i]);
        size_t best = 0, dist = 0, limit = std::min(n - i, MAX_MATCH);
        int32_t cand = head[h];
        for (int probes = 0; cand >= 0 && i - size_t(cand) <= MAX_DIST && probes < MAX_CHAIN; probes++) {
            size_t len = 0;
            while (len < limit && in[cand + len] == in[i + len]) len++;
            if (len > best) {
                best = len;
                dist = i - size_t(cand);
                if (len == limit) break;
            }
            cand = prev[cand & (WINDOW - 1)];
        }
        prev[i & (WINDOW - 1)] = head[h];
        head[h] = int32_t(i);
        if (best >= MIN_MATCH) {
            put_literals(lit, i);
            out.push_back(uint8_t(128 + best - MIN_MATCH));
            out.push_back(uint8_t(dist));
            out.push_back(uint8_t(dist >> 8));
            // the positions inside the match go into the table too
            for (size_t j = i + 1; j < i + best && j + MIN_MATCH <= n; j++) {
                uint32_t hj = hash4(&in[j]);
                prev[j & (WINDOW - 1)] = head[hj];
                head[hj] = int32_t(j);
            }
            i += best;
            lit = i;
        } else {
            i++;
        }
    }
    put_literals(lit, n);
    return out;
}

// expected is the size to reserve room for
static std::vector<uint8_t> decompress(std::span<const uint8_t> in, size_t expected) {
    std::vector<uint8_t> out;
    out.reserve(expected);
    size_t p = 0;
    while (p < in.size()) {
        unsigned c = in[p++];
        if (c < 128) {
            size_t k = c + 1;
            if (in.size() - p < k) throw std::runtime_error("literals past the end");
            out.insert(out.end(), in.begin() + p, in.begin() + p + k);
            p += k;
        } else {
            if (in.size() - p < 2) throw std::runtime_error("match past the end");
            size_t len = c - 128 + MIN_MATCH, dist = in[p] | size_t(in[p + 1]) << 8;
            p += 2;
            if (dist == 0 || dist > out.size()) throw std::runtime_error("distance out of range");
            size_t from = out.size() - dist; // may overlap what it writes: a byte at a time
            for (size_t k = 0; k < len; k++) out.push_back(out[from + k]);
        }
    }
    return out;
}

static uint64_t x = 88172645463325252ULL;

static uint64_t next() {
    x ^= x << 13;
    x ^= x >> 7;
    x ^= x << 17;
    return x;
}

int main(int argc, char **argv) {
    size_t n = argc > 1 ? size_t(std::atol(argv[1])) : size_t(64) << 20;
    // the text: words from a 1024-word vocabulary (the first ones the most common), and now and
    // then a phrase repeated from up to 32 KiB back
    std::vector<std::string> words(1024);
    for (auto &w : words) {
        w.resize(2 + next() % 8);
        for (auto &ch : w) ch = char('a' + next() % 26);
    }
    std::string text;
    text.reserve(n + 128);
    while (text.size() < n) {
        uint64_t r = next();
        if (r % 16 == 0 && text.size() >= 64) {
            size_t span = std::min<size_t>(text.size(), 32768);
            size_t dist = 1 + next() % span, count = 16 + next() % 48;
            for (size_t k = 0; k < count; k++) text.push_back(text[text.size() - dist]);
        } else {
            text += words[((r >> 8) % 1024) * ((r >> 20) % 1024) / 1024];
            switch ((r >> 40) % 16) {
            case 0: text += ".\n"; break;
            case 1: text += ", "; break;
            default: text += ' ';
            }
        }
    }
    text.resize(n);
    std::span<const uint8_t> input(reinterpret_cast<const uint8_t *>(text.data()), n);
    try {
        auto packed = compress(input);
        auto back = decompress(packed, n);
        if (!std::equal(back.begin(), back.end(), input.begin(), input.end())) {
            std::fprintf(stderr, "round trip failed\n");
            return 1;
        }
        uint64_t check = 14695981039346656037ull;
        for (uint8_t b : packed) check = (check ^ b) * 1099511628211ull;
        std::printf("%zu %zu %llu\n", n, packed.size(), (unsigned long long)check);
    } catch (const std::exception &e) {
        std::fprintf(stderr, "corrupt: %s\n", e.what());
        return 1;
    }
}
