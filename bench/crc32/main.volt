// crc32: the table-driven CRC-32 of a pseudo-random buffer, a byte at a time
use std::io;
use std::text;

fn main() -> !void {
    val n = @cast<usize>((std::process::arg(1) ?? "268435456").parse_int() catch 268435456);
    var table: u32[256];
    for (i) in 0..256 {
        var c = @cast<u32>(i);
        for (k) in 0..8 {
            if ((c & 1) != 0) {
                c = 0xEDB88320 ^ (c >> 1);
            } else {
                c = c >> 1;
            }
        }
        table[i] = c;
    }
    var buf: std::vec<u8> = {};
    try buf.reserve(n);
    var s: u64 = 1;
    for (i) in 0..n {
        s = s *% 6364136223846793005 +% 1442695040888963407;
        try buf.push(@cast<u8>(s >> 56));
    }
    var crc: u32 = 0xFFFFFFFF;
    for (b) in buf.items() {
        crc = table[(crc ^ @cast<u32>(b)) & 0xFF] ^ (crc >> 8);
    }
    std::println("{:08x}", crc ^ 0xFFFFFFFF);
}
