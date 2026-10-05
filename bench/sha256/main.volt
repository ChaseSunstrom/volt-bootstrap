// sha256: the SHA-256 digest (FIPS 180-4) of a pseudo-random buffer, a 64-byte block at a time;
// Volt keeps the state in a struct of u32 arrays with attached methods, and adds with +%
use std::io;
use std::fmt;
use std::text;

val K: u32[64] = {
    0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
    0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
    0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
    0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
    0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
    0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
    0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
    0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
};

struct sha256 {
    h: u32[8] = { 0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a, 0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19 };
    block: u8[64] = {}; // bytes waiting for a whole block
    filled: usize = 0;
    total: u64 = 0;
}

fn rotr(x: u32, n: u32) -> u32 {
    return (x >> n) | (x << (32 - n));
}

attach fn compress(this: sha256&, b: u8[..]) -> void {
    var w: u32[64];
    for (i) in 0..16 {
        w[i] = (@cast<u32>(b[4 * i]) << 24) | (@cast<u32>(b[4 * i + 1]) << 16) | (@cast<u32>(b[4 * i + 2]) << 8) | @cast<u32>(b[4 * i + 3]);
    }
    for (i) in 16..64 {
        val s0 = rotr(w[i - 15], 7) ^ rotr(w[i - 15], 18) ^ (w[i - 15] >> 3);
        val s1 = rotr(w[i - 2], 17) ^ rotr(w[i - 2], 19) ^ (w[i - 2] >> 10);
        w[i] = w[i - 16] +% s0 +% w[i - 7] +% s1;
    }
    var (a, bb, c, d, e, f, g, hh) = (this.h[0], this.h[1], this.h[2], this.h[3], this.h[4], this.h[5], this.h[6], this.h[7]);
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
    this.h[0] +%= a;
    this.h[1] +%= bb;
    this.h[2] +%= c;
    this.h[3] +%= d;
    this.h[4] +%= e;
    this.h[5] +%= f;
    this.h[6] +%= g;
    this.h[7] +%= hh;
}

attach fn update(this: sha256&, data: u8[..]) -> void {
    var i: usize = 0;
    this.total +%= @cast<u64>(data.len);
    if (this.filled > 0) {
        while (i < data.len && this.filled < 64) {
            this.block[this.filled] = data[i];
            this.filled += 1;
            i += 1;
        }
        if (this.filled < 64) {
            return;
        }
        this.compress(this.block[..]);
        this.filled = 0;
    }
    while (i + 64 <= data.len) {
        this.compress(data[i..i + 64]);
        i += 64;
    }
    while (i < data.len) {
        this.block[this.filled] = data[i];
        this.filled += 1;
        i += 1;
    }
}

attach fn finish(this: sha256&) -> u8[32] {
    val bits = this.total *% 8;
    var tail: u8[72];
    tail[0] = 0x80;
    var n: usize = 64 - (this.filled + 8) % 64;
    if (n == 0) {
        n = 64;
    }
    for (k) in 0..8 {
        tail[n + @cast<usize>(k)] = @cast<u8>(bits >> (56 - 8 * @cast<u64>(k)));
    }
    this.update(tail[0..n + 8]);
    var out: u8[32];
    for (i) in 0..8 {
        out[4 * i] = @cast<u8>(this.h[i] >> 24);
        out[4 * i + 1] = @cast<u8>(this.h[i] >> 16);
        out[4 * i + 2] = @cast<u8>(this.h[i] >> 8);
        out[4 * i + 3] = @cast<u8>(this.h[i]);
    }
    return out;
}

fn hex(d: u8[32]) -> std::string {
    var s: std::string = {};
    for (b) in d {
        std::write(&s, "{:02x}", b);
    }
    return s;
}

var x: u64 = 88172645463325252;

fn next() -> u64 {
    x = x ^ (x << 13);
    x = x ^ (x >> 7);
    x = x ^ (x << 17);
    return x;
}

fn main() -> !void {
    val n = @cast<usize>((std::process::arg(1) ?? "268435456").parse_int() catch 268435456);
    var abc: sha256 = {};
    abc.update(@cast<u8[..]>("abc"));
    val got = hex(abc.finish());
    if (got.as_str() != "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad") {
        std::eprintln("sha256(\"abc\") is wrong: {}", got);
        std::process::exit(1);
    }
    std::println("abc {}", got);
    var buf: std::vec<u8> = {};
    try buf.reserve(n);
    for (i) in 0..n {
        try buf.push(@cast<u8>(next() >> 56));
    }
    var s: sha256 = {};
    s.update(buf.items());
    std::println("{} {}", n, hex(s.finish()));
}
