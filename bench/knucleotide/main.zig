// k-nucleotide (the Benchmarks Game): count the k-mers of a long DNA string, k = 1 and 2 as sorted
// frequencies, and five longer ones (up to 18 bases) by building a table for each length; Zig packs
// the bases 2 bits each into a u64 key, counted in a std.AutoHashMapUnmanaged
const std = @import("std");
const Allocator = std.mem.Allocator;
const Counts = std.AutoHashMapUnmanaged(u64, u32);

// every k-mer of codes, its bases 2 bits each
fn count(gpa: Allocator, codes: []const u8, k: usize) !Counts {
    const mask = (@as(u64, 1) << @intCast(2 * k)) - 1;
    var key: u64 = 0;
    var counts: Counts = .empty;
    for (codes, 0..) |c, i| {
        key = ((key << 2) | c) & mask;
        if (i + 1 >= k) {
            const e = try counts.getOrPut(gpa, key);
            e.value_ptr.* = if (e.found_existing) e.value_ptr.* + 1 else 1;
        }
    }
    return counts;
}

const LETTERS = "ACGT";

const Entry = struct { key: u64, count: u32 };

// most frequent first; same length, so key order is letter order
fn byCount(_: void, a: Entry, b: Entry) bool {
    if (a.count != b.count) return a.count > b.count;
    return a.key < b.key;
}

fn frequencies(gpa: Allocator, w: *std.Io.Writer, codes: []const u8, k: usize) !void {
    var counts = try count(gpa, codes, k);
    defer counts.deinit(gpa);
    const all = try gpa.alloc(Entry, counts.count());
    defer gpa.free(all);
    var it = counts.iterator();
    var m: usize = 0;
    while (it.next()) |e| : (m += 1) all[m] = .{ .key = e.key_ptr.*, .count = e.value_ptr.* };
    std.mem.sort(Entry, all, {}, byCount);
    var name: [32]u8 = undefined;
    for (all) |e| {
        for (name[0..k], 0..) |*ch, j| ch.* = LETTERS[@intCast((e.key >> @intCast(2 * (k - 1 - j))) & 3)];
        const pct = 100.0 * @as(f64, @floatFromInt(e.count)) / @as(f64, @floatFromInt(codes.len - k + 1));
        try w.print("{s} {d:.3}\n", .{ name[0..k], pct });
    }
    try w.print("\n", .{});
}

fn codeOf(c: u8) u8 {
    return switch (c) {
        'A' => 0,
        'C' => 1,
        'G' => 2,
        else => 3,
    };
}

fn occurrences(gpa: Allocator, w: *std.Io.Writer, codes: []const u8, seq: []const u8) !void {
    var key: u64 = 0;
    for (seq) |c| key = (key << 2) | codeOf(c);
    var counts = try count(gpa, codes, seq.len);
    defer counts.deinit(gpa);
    try w.print("{d}\t{s}\n", .{ counts.get(key) orelse 0, seq });
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
    const n: usize = if (args.next()) |s| try std.fmt.parseInt(usize, s, 10) else 25000000;
    // the bases at the human genome's frequencies; the generator that made the original input
    // (fasta) repeats every 139968 numbers, so this sequence repeats with that period too
    const period = 139968;
    const dna = try gpa.alloc(u8, n);
    defer gpa.free(dna);
    for (dna, 0..) |*base, i| {
        if (i >= period) {
            base.* = dna[i - period];
            continue;
        }
        const r = (next() >> 32) % 1000;
        base.* = if (r < 303) 'A' else if (r < 501) 'C' else if (r < 699) 'G' else 'T';
    }
    const codes = try gpa.alloc(u8, n);
    defer gpa.free(codes);
    for (codes, dna) |*c, base| c.* = codeOf(base);
    var buf: [4096]u8 = undefined;
    var fw = std.Io.File.stdout().writer(init.io, &buf);
    const w = &fw.interface;
    try frequencies(gpa, w, codes, 1);
    try frequencies(gpa, w, codes, 2);
    for ([_][]const u8{ "GGT", "GGTA", "GGTATT", "GGTATTTTAATT", "GGTATTTTAATTTATAGT" }) |seq| try occurrences(gpa, w, codes, seq);
    try w.flush();
}
