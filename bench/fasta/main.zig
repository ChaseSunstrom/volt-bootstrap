// fasta (the Benchmarks Game): generate three DNA sequences, n*2 bases repeating the ALU string, then
// n*3 and n*5 bases drawn by a linear congruential generator from cumulative probability tables, in
// FASTA lines of 60; prints each one's header, length and an FNV-1a checksum of its lines in place of
// the text. Zig builds the cumulative tables at comptime
const std = @import("std");

const ALU = "GGCCGGGCGCGGTGGCTCACGCCTGTAATCCCAGCACTTTGGGAGGCCGAGGCGGGCGGATCACCTGAGGTCAGGAGTTCGAGACCAGCC" ++
    "TGGCCAACATGGTGAAACCCCGTCTCTACTAAAAATACAAAAATTAGCCGGGCGTGGTGGCGCGCGCCTGTAATCCCAGCTACTCGGGAG" ++
    "GCTGAGGCAGGAGAATCGCTTGAACCCGGGAGGCGGAGGTTGCAGTGAGCCGAGATCGCGCCACTGCACTCCAGCCTGGGCGACAGAGCGA" ++
    "GACTCCGTCTCAAAAA";

const Acid = struct { c: u8, p: f64 };

// each p becomes the sum of the ones up to it
fn cumulative(comptime t: anytype) @TypeOf(t) {
    var out = t;
    var sum: f64 = 0;
    for (&out) |*a| {
        sum += a.p;
        a.p = sum;
    }
    return out;
}

const IUB = cumulative([_]Acid{
    .{ .c = 'a', .p = 0.27 }, .{ .c = 'c', .p = 0.12 }, .{ .c = 'g', .p = 0.12 }, .{ .c = 't', .p = 0.27 },
    .{ .c = 'B', .p = 0.02 }, .{ .c = 'D', .p = 0.02 }, .{ .c = 'H', .p = 0.02 }, .{ .c = 'K', .p = 0.02 },
    .{ .c = 'M', .p = 0.02 }, .{ .c = 'N', .p = 0.02 }, .{ .c = 'R', .p = 0.02 }, .{ .c = 'S', .p = 0.02 },
    .{ .c = 'V', .p = 0.02 }, .{ .c = 'W', .p = 0.02 }, .{ .c = 'Y', .p = 0.02 },
});

const HOMO_SAPIENS = cumulative([_]Acid{
    .{ .c = 'a', .p = 0.3029549426680 }, .{ .c = 'c', .p = 0.1979883004921 },
    .{ .c = 'g', .p = 0.1975473066391 }, .{ .c = 't', .p = 0.3015094502008 },
});

const IM = 139968;
const IA = 3877;
const IC = 29573;

var seed: u32 = 42;

fn randomUnit() f64 {
    seed = (seed * IA + IC) % IM;
    return @as(f64, @floatFromInt(seed)) / IM;
}

fn fnv(h0: u64, s: []const u8) u64 {
    var h = h0;
    for (s) |c| h = (h ^ c) *% 1099511628211;
    return h;
}

fn repeat(w: *std.Io.Writer, header: []const u8, s: []const u8, n: usize) !void {
    var pos: usize = 0;
    var line: [61]u8 = undefined;
    var h: u64 = 14695981039346656037;
    var done: usize = 0;
    while (done < n) {
        const m = @min(n - done, 60);
        for (line[0..m]) |*c| {
            c.* = s[pos];
            pos += 1;
            if (pos == s.len) pos = 0;
        }
        line[m] = '\n';
        h = fnv(h, line[0 .. m + 1]);
        done += m;
    }
    try w.print("{s}: {d} bases, checksum {d}\n", .{ header, n, h });
}

fn randomBases(w: *std.Io.Writer, header: []const u8, t: []const Acid, n: usize) !void {
    var line: [61]u8 = undefined;
    var h: u64 = 14695981039346656037;
    var done: usize = 0;
    while (done < n) {
        const m = @min(n - done, 60);
        for (line[0..m]) |*c| {
            const r = randomUnit();
            var k: usize = 0;
            while (k < t.len - 1 and r >= t[k].p) k += 1;
            c.* = t[k].c;
        }
        line[m] = '\n';
        h = fnv(h, line[0 .. m + 1]);
        done += m;
    }
    try w.print("{s}: {d} bases, checksum {d}\n", .{ header, n, h });
}

pub fn main(init: std.process.Init) !void {
    var args = init.minimal.args.iterate();
    _ = args.skip();
    const n: usize = if (args.next()) |s| try std.fmt.parseInt(usize, s, 10) else 10000000;
    var buf: [256]u8 = undefined;
    var fw = std.Io.File.stdout().writer(init.io, &buf);
    const w = &fw.interface;
    try repeat(w, ">ONE Homo sapiens alu", ALU, n * 2);
    try randomBases(w, ">TWO IUB ambiguity codes", &IUB, n * 3);
    try randomBases(w, ">THREE Homo sapiens frequency", &HOMO_SAPIENS, n * 5);
    try w.flush();
}
