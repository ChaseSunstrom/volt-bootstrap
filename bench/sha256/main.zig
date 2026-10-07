// sha256: the SHA-256 digest (FIPS 180-4) of a pseudo-random buffer, a 64-byte block at a time
const std = @import("std");
const rotr = std.math.rotr;

const K = [64]u32{
    0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
    0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
    0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
    0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
    0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
    0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
    0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
    0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
};

const Sha256 = struct {
    h: [8]u32 = .{ 0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a, 0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19 },
    block: [64]u8 = undefined, // bytes waiting for a whole block
    filled: usize = 0,
    total: u64 = 0,

    fn compress(h: *[8]u32, b: *const [64]u8) void {
        var w: [64]u32 = undefined;
        for (0..16) |i| w[i] = std.mem.readInt(u32, b[4 * i ..][0..4], .big);
        for (16..64) |i| {
            const s0 = rotr(u32, w[i - 15], 7) ^ rotr(u32, w[i - 15], 18) ^ (w[i - 15] >> 3);
            const s1 = rotr(u32, w[i - 2], 17) ^ rotr(u32, w[i - 2], 19) ^ (w[i - 2] >> 10);
            w[i] = w[i - 16] +% s0 +% w[i - 7] +% s1;
        }
        var a = h[0];
        var bb = h[1];
        var c = h[2];
        var d = h[3];
        var e = h[4];
        var f = h[5];
        var g = h[6];
        var hh = h[7];
        for (0..64) |i| {
            const bsig1 = rotr(u32, e, 6) ^ rotr(u32, e, 11) ^ rotr(u32, e, 25);
            const ch = (e & f) ^ (~e & g);
            const t1 = hh +% bsig1 +% ch +% K[i] +% w[i];
            const bsig0 = rotr(u32, a, 2) ^ rotr(u32, a, 13) ^ rotr(u32, a, 22);
            const maj = (a & bb) ^ (a & c) ^ (bb & c);
            const t2 = bsig0 +% maj;
            hh = g;
            g = f;
            f = e;
            e = d +% t1;
            d = c;
            c = bb;
            bb = a;
            a = t1 +% t2;
        }
        for (h, [8]u32{ a, bb, c, d, e, f, g, hh }) |*x, y| x.* +%= y;
    }

    fn update(s: *Sha256, input: []const u8) void {
        var data = input;
        s.total += data.len;
        if (s.filled > 0) {
            const take = @min(data.len, 64 - s.filled);
            @memcpy(s.block[s.filled..][0..take], data[0..take]);
            s.filled += take;
            data = data[take..];
            if (s.filled < 64) return;
            compress(&s.h, &s.block);
            s.filled = 0;
        }
        while (data.len >= 64) : (data = data[64..]) compress(&s.h, data[0..64]);
        @memcpy(s.block[0..data.len], data);
        s.filled = data.len;
    }

    fn final(s: *Sha256) [32]u8 {
        const bits = s.total * 8;
        var tail: [72]u8 = @splat(0);
        tail[0] = 0x80;
        var n = 64 - (s.filled + 8) % 64;
        if (n == 0) n = 64;
        std.mem.writeInt(u64, tail[n..][0..8], bits, .big);
        s.update(tail[0 .. n + 8]);
        var out: [32]u8 = undefined;
        for (s.h, 0..) |h, i| std.mem.writeInt(u32, out[4 * i ..][0..4], h, .big);
        return out;
    }
};

pub fn main(init: std.process.Init) !void {
    var args = init.minimal.args.iterate();
    _ = args.skip();
    const n: usize = if (args.next()) |a| try std.fmt.parseInt(usize, a, 10) else 256 << 20;
    var obuf: [256]u8 = undefined;
    var w = std.Io.File.stdout().writer(init.io, &obuf);
    const out = &w.interface;

    var s: Sha256 = .{};
    s.update("abc");
    const text = std.fmt.bytesToHex(s.final(), .lower);
    if (!std.mem.eql(u8, &text, "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")) {
        std.debug.print("sha256(\"abc\") is wrong: {s}\n", .{&text});
        std.process.exit(1);
    }
    try out.print("abc {s}\n", .{&text});

    const buf = try init.gpa.alloc(u8, n);
    defer init.gpa.free(buf);
    var x: u64 = 88172645463325252;
    for (buf) |*b| {
        x ^= x << 13;
        x ^= x >> 7;
        x ^= x << 17;
        b.* = @intCast(x >> 56);
    }
    s = .{};
    s.update(buf);
    try out.print("{d} {s}\n", .{ n, &std.fmt.bytesToHex(s.final(), .lower) });
    try out.flush();
}
