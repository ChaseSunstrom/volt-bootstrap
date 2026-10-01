// std::digest: checksums and hashes of bytes: CRC-32, 64-bit FNV-1a and SHA-256.
// (Part of package std: the package loader wraps every file in `namespace std`.)

namespace digest {
    // CRC-32 for a nibble (the reflected 0xEDB88320 polynomial): two lookups a byte
    internal val CRC_NIBBLE: u32[16] = {
        0x00000000, 0x1DB71064, 0x3B6E20C8, 0x26D930AC, 0x76DC4190, 0x6B6B51F4, 0x4DB26158, 0x5005713C,
        0xEDB88320, 0xF00F9344, 0xD6D6A3E8, 0xCB61B38C, 0x9B64C2B0, 0x86D3D2D4, 0xA00AE278, 0xBDBDF21C,
    };

    // the CRC-32 of data, as zip, gzip and PNG compute it ("123456789" gives cbf43926)
    fn crc32(data: u8[..]) -> u32 {
        var crc: u32 = 0xFFFFFFFF;
        for (b) in data {
            crc = crc ^ @cast<u32>(b);
            crc = (crc >> 4) ^ CRC_NIBBLE[crc & 15];
            crc = (crc >> 4) ^ CRC_NIBBLE[crc & 15];
        }
        return crc ^ 0xFFFFFFFF;
    }

    fn crc32(text: str) -> u32 {
        return crc32(@cast<u8[..]>(text));
    }

    // the 64-bit FNV-1a hash of data: fast and simple, for hash tables and fingerprints (not for
    // anything an attacker controls)
    fn fnv1a(data: u8[..]) -> u64 {
        var h: u64 = 14695981039346656037;
        for (b) in data {
            h = (h ^ @cast<u64>(b)) *% 1099511628211;
        }
        return h;
    }

    fn fnv1a(text: str) -> u64 {
        return fnv1a(@cast<u8[..]>(text));
    }

    // SHA-256's round constants
    internal val K: u32[64] = {
        0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
        0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
        0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
        0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
        0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
        0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
        0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
        0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
    };

    // SHA-256 (FIPS 180-4), fed in pieces: update with each, then finish for the 32-byte digest.
    // Make one with sha256::new()
    struct sha256 {
        h: u32[8];      // the state
        block: u8[64];  // bytes waiting for a whole block
        filled: usize;  // how many of block are in use
        total: u64;     // bytes taken so far
    }

    // the digest of data in one call
    fn sha256_of(data: u8[..]) -> u8[32] {
        var s = sha256::new();
        s.update(data);
        return s.finish();
    }

    fn sha256_of(text: str) -> u8[32] {
        return sha256_of(@cast<u8[..]>(text));
    }

    internal fn rotr(x: u32, n: u32) -> u32 {
        return (x >> n) | (x << (32 - n));
    }

    // one 64-byte block into the state
    internal fn compress(h: u32[8]&, b: u8[..]) -> void {
        var w: u32[64];
        for (i) in 0..16 {
            w[i] = (@cast<u32>(b[4 * i]) << 24) | (@cast<u32>(b[4 * i + 1]) << 16) | (@cast<u32>(b[4 * i + 2]) << 8) | @cast<u32>(b[4 * i + 3]);
        }
        for (i) in 16..64 {
            val s0 = rotr(w[i - 15], 7) ^ rotr(w[i - 15], 18) ^ (w[i - 15] >> 3);
            val s1 = rotr(w[i - 2], 17) ^ rotr(w[i - 2], 19) ^ (w[i - 2] >> 10);
            w[i] = w[i - 16] +% s0 +% w[i - 7] +% s1;
        }
        var (a, bb, c, d, e, f, g, hh) = ((*h)[0], (*h)[1], (*h)[2], (*h)[3], (*h)[4], (*h)[5], (*h)[6], (*h)[7]);
        for (i) in 0..64 {
            val s1 = rotr(e, 6) ^ rotr(e, 11) ^ rotr(e, 25);
            val ch = (e & f) ^ (~e & g);
            val t1 = hh +% s1 +% ch +% K[i] +% w[i];
            val s0 = rotr(a, 2) ^ rotr(a, 13) ^ rotr(a, 22);
            val maj = (a & bb) ^ (a & c) ^ (bb & c);
            val t2 = s0 +% maj;
            hh = g;
            g = f;
            f = e;
            e = d +% t1;
            d = c;
            c = bb;
            bb = a;
            a = t1 +% t2;
        }
        (*h)[0] = (*h)[0] +% a;
        (*h)[1] = (*h)[1] +% bb;
        (*h)[2] = (*h)[2] +% c;
        (*h)[3] = (*h)[3] +% d;
        (*h)[4] = (*h)[4] +% e;
        (*h)[5] = (*h)[5] +% f;
        (*h)[6] = (*h)[6] +% g;
        (*h)[7] = (*h)[7] +% hh;
    }
}

// a SHA-256 hasher with nothing fed in yet
attach fn new(static this: std::digest::sha256) -> std::digest::sha256 {
    val iv: u32[8] = { 0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a, 0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19 };
    var block: u8[64];
    return { h: iv, block: block, filled: 0, total: 0 };
}

// feed data in
attach fn update(this: std::digest::sha256&, data: u8[..]) -> void {
    var i: usize = 0;
    this.total +%= @cast<u64>(data.len);
    // top up a partly filled block first
    if (this.filled > 0) {
        while (i < data.len && this.filled < 64) {
            this.block[this.filled] = data[i];
            this.filled += 1;
            i += 1;
        }
        if (this.filled < 64) {
            return;
        }
        std::digest::compress(&this.h, this.block[..]);
        this.filled = 0;
    }
    // whole blocks straight from data
    while (i + 64 <= data.len) {
        std::digest::compress(&this.h, data[i..i + 64]);
        i += 64;
    }
    while (i < data.len) {
        this.block[this.filled] = data[i];
        this.filled += 1;
        i += 1;
    }
}

attach fn update(this: std::digest::sha256&, text: str) -> void {
    this.update(@cast<u8[..]>(text));
}

// the digest of everything fed in (the hasher is used up: make a new one for more)
attach fn finish(this: std::digest::sha256&) -> u8[32] {
    val bits = this.total *% 8;
    // a 1 bit, zeros to 56 bytes into a block, then the length in bits, big-endian
    var tail: u8[72];
    tail[0] = 0x80;
    var n: usize = 64 - (this.filled + 8) % 64;
    if (n == 0) {
        n = 64;
    }
    for (k) in 0..8 {
        tail[n + @cast<usize>(k)] = @cast<u8>((bits >> (56 - 8 * @cast<u64>(k))) & 0xff);
    }
    this.update(tail[0..n + 8]);
    var out: u8[32];
    for (i) in 0..8 {
        out[4 * i] = @cast<u8>(this.h[i] >> 24);
        out[4 * i + 1] = @cast<u8>((this.h[i] >> 16) & 0xff);
        out[4 * i + 2] = @cast<u8>((this.h[i] >> 8) & 0xff);
        out[4 * i + 3] = @cast<u8>(this.h[i] & 0xff);
    }
    return out;
}
