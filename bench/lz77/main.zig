// lz77: compress a repetitive text with LZ77 (a hash table of recent positions, chains of at most 8
// probes, a 64 KiB window), decompress it and check the round trip; Zig works on allocated slices
// with indices, and the decoder returns error.Corrupt for corrupt input
const std = @import("std");

// the format: a byte c < 128 is followed by c + 1 literal bytes; c >= 128 is a match of
// c - 128 + MIN_MATCH bytes, then its distance back (1..MAX_DIST) in two bytes, low first
const HASH_BITS = 16;
const WINDOW = 1 << 16;
const MIN_MATCH = 4;
const MAX_MATCH = MIN_MATCH + 127;
const MAX_CHAIN = 8;
const MAX_DIST = WINDOW - 1;

fn hash4(p: []const u8) usize {
    const v = std.mem.readInt(u32, p[0..4], .little);
    return (v *% 2654435761) >> (32 - HASH_BITS);
}

fn putLiterals(out: []u8, o: usize, lits: []const u8) usize {
    var at = o;
    var rest = lits;
    while (rest.len > 0) {
        const k = @min(rest.len, 128);
        out[at] = @intCast(k - 1);
        @memcpy(out[at + 1 ..][0..k], rest[0..k]);
        at += 1 + k;
        rest = rest[k..];
    }
    return at;
}

// compresses in into out, which has room for n + n / 128 + 16 bytes; returns the size
fn compress(gpa: std.mem.Allocator, in: []const u8, out: []u8) !usize {
    const n = in.len;
    const head = try gpa.alloc(i32, 1 << HASH_BITS);
    defer gpa.free(head);
    const prev = try gpa.alloc(i32, WINDOW);
    defer gpa.free(prev);
    @memset(head, -1);
    var o: usize = 0;
    var i: usize = 0;
    var lit: usize = 0;
    while (i + MIN_MATCH <= n) {
        const h = hash4(in[i..]);
        var best: usize = 0;
        var dist: usize = 0;
        const limit = @min(n - i, MAX_MATCH);
        var cand = head[h];
        var probes: usize = 0;
        while (cand >= 0 and i - @as(usize, @intCast(cand)) <= MAX_DIST and probes < MAX_CHAIN) : (probes += 1) {
            const c: usize = @intCast(cand);
            const len = std.mem.indexOfDiff(u8, in[c..][0..limit], in[i..][0..limit]) orelse limit;
            if (len > best) {
                best = len;
                dist = i - c;
                if (len == limit) break;
            }
            cand = prev[c & (WINDOW - 1)];
        }
        prev[i & (WINDOW - 1)] = head[h];
        head[h] = @intCast(i);
        if (best >= MIN_MATCH) {
            o = putLiterals(out, o, in[lit..i]);
            out[o] = @intCast(128 + best - MIN_MATCH);
            out[o + 1] = @truncate(dist);
            out[o + 2] = @truncate(dist >> 8);
            o += 3;
            // the positions inside the match go into the table too
            var j = i + 1;
            while (j < i + best and j + MIN_MATCH <= n) : (j += 1) {
                const hj = hash4(in[j..]);
                prev[j & (WINDOW - 1)] = head[hj];
                head[hj] = @intCast(j);
            }
            i += best;
            lit = i;
        } else {
            i += 1;
        }
    }
    return putLiterals(out, o, in[lit..n]);
}

// decompresses src into dst; returns the size, or error.Corrupt when the input is corrupt
fn decompress(src: []const u8, dst: []u8) error{Corrupt}!usize {
    var p: usize = 0;
    var o: usize = 0;
    while (p < src.len) {
        const c: usize = src[p];
        p += 1;
        if (c < 128) {
            const k = c + 1;
            if (src.len - p < k or dst.len - o < k) return error.Corrupt;
            @memcpy(dst[o..][0..k], src[p..][0..k]);
            o += k;
            p += k;
        } else {
            if (src.len - p < 2) return error.Corrupt;
            const len = c - 128 + MIN_MATCH;
            const dist = @as(usize, src[p]) | @as(usize, src[p + 1]) << 8;
            p += 2;
            if (dist == 0 or dist > o or dst.len - o < len) return error.Corrupt;
            // may overlap what it writes: a byte at a time
            for (0..len) |k| dst[o + k] = dst[o - dist + k];
            o += len;
        }
    }
    return o;
}

var x: u64 = 88172645463325252;

fn next() u64 {
    x ^= x << 13;
    x ^= x >> 7;
    x ^= x << 17;
    return x;
}

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    var args = init.minimal.args.iterate();
    _ = args.skip();
    const n: usize = if (args.next()) |s| try std.fmt.parseInt(usize, s, 10) else 64 << 20;
    // the text: words from a 1024-word vocabulary (the first ones the most common), and now and
    // then a phrase repeated from up to 32 KiB back
    var words: [1024][10]u8 = undefined;
    var wlen: [1024]usize = undefined;
    for (&words, &wlen) |*word, *len| {
        len.* = 2 + next() % 8;
        for (word[0..len.*]) |*ch| ch.* = 'a' + @as(u8, @intCast(next() % 26));
    }
    const text = try gpa.alloc(u8, n + 128);
    defer gpa.free(text);
    var len: usize = 0;
    while (len < n) {
        const r = next();
        if (r % 16 == 0 and len >= 64) {
            const span = @min(len, 32768);
            const dist = 1 + next() % span;
            const count = 16 + next() % 48;
            for (0..count) |_| {
                text[len] = text[len - dist];
                len += 1;
            }
        } else {
            const w = ((r >> 8) % 1024) * ((r >> 20) % 1024) / 1024;
            @memcpy(text[len..][0..wlen[w]], words[w][0..wlen[w]]);
            len += wlen[w];
            const sep: []const u8 = switch ((r >> 40) % 16) {
                0 => ".\n",
                1 => ", ",
                else => " ",
            };
            @memcpy(text[len..][0..sep.len], sep);
            len += sep.len;
        }
    }
    const packed_buf = try gpa.alloc(u8, n + n / 128 + 16);
    defer gpa.free(packed_buf);
    const packed_data = packed_buf[0..try compress(gpa, text[0..n], packed_buf)];
    const back = try gpa.alloc(u8, n);
    defer gpa.free(back);
    const back_len = decompress(packed_data, back) catch 0;
    if (back_len != n or !std.mem.eql(u8, back, text[0..n])) {
        std.debug.print("round trip failed\n", .{});
        std.process.exit(1);
    }
    var check: u64 = 14695981039346656037;
    for (packed_data) |b| check = (check ^ b) *% 1099511628211;
    var buf: [256]u8 = undefined;
    var fw = std.Io.File.stdout().writer(init.io, &buf);
    try fw.interface.print("{d} {d} {d}\n", .{ n, packed_data.len, check });
    try fw.interface.flush();
}
