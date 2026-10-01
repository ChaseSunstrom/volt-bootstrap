// crc32: the table-driven CRC-32 of a pseudo-random buffer, a byte at a time
#include <array>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <vector>

int main(int argc, char **argv) {
    std::size_t n = argc > 1 ? std::size_t(std::atol(argv[1])) : std::size_t(256) << 20;
    std::array<std::uint32_t, 256> table;
    for (std::uint32_t i = 0; i < 256; i++) {
        std::uint32_t c = i;
        for (int k = 0; k < 8; k++) c = c & 1 ? 0xEDB88320u ^ (c >> 1) : c >> 1;
        table[i] = c;
    }
    std::vector<std::uint8_t> buf(n);
    std::uint64_t s = 1;
    for (auto &b : buf) {
        s = s * 6364136223846793005u + 1442695040888963407u;
        b = std::uint8_t(s >> 56);
    }
    std::uint32_t crc = 0xFFFFFFFFu;
    for (auto b : buf) crc = table[(crc ^ b) & 0xFF] ^ (crc >> 8);
    std::printf("%08x\n", crc ^ 0xFFFFFFFFu);
}
