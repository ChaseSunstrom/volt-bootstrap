// crc32: the table-driven CRC-32 of a pseudo-random buffer, a byte at a time
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>

int main(int argc, char **argv) {
    size_t n = argc > 1 ? (size_t)atol(argv[1]) : 256u << 20;
    uint32_t table[256];
    for (uint32_t i = 0; i < 256; i++) {
        uint32_t c = i;
        for (int k = 0; k < 8; k++) c = c & 1 ? 0xEDB88320u ^ (c >> 1) : c >> 1;
        table[i] = c;
    }
    uint8_t *buf = malloc(n);
    uint64_t s = 1;
    for (size_t i = 0; i < n; i++) {
        s = s * 6364136223846793005u + 1442695040888963407u;
        buf[i] = (uint8_t)(s >> 56);
    }
    uint32_t crc = 0xFFFFFFFFu;
    for (size_t i = 0; i < n; i++) crc = table[(crc ^ buf[i]) & 0xFF] ^ (crc >> 8);
    printf("%08x\n", crc ^ 0xFFFFFFFFu);
    free(buf);
    return 0;
}
