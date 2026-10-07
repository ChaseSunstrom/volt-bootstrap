// wordfreq: count the words of a text of n words drawn from a Zipf-like vocabulary in a std.StringHashMap, then print the 20 most frequent
const std = @import("std");

const vocab = 1 << 18;

var x: u64 = 88172645463325252;

fn next() u64 {
    x ^= x << 13;
    x ^= x >> 7;
    x ^= x << 17;
    return x;
}

const Entry = struct { word: []const u8, count: i64 };

// most frequent first, ties alphabetically
fn byCount(_: void, a: Entry, b: Entry) bool {
    if (a.count != b.count) return a.count > b.count;
    return std.mem.lessThan(u8, a.word, b.word);
}

pub fn main(init: std.process.Init) !void {
    var args = init.minimal.args.iterate();
    _ = args.skip();
    const n: i64 = if (args.next()) |a| try std.fmt.parseInt(i64, a, 10) else 20000000;
    const gpa = init.gpa;
    // the vocabulary: random lowercase words of 3 to 10 letters
    const words = try gpa.alloc([10]u8, vocab);
    defer gpa.free(words);
    const lens = try gpa.alloc(usize, vocab);
    defer gpa.free(lens);
    for (words, lens) |*word, *len| {
        len.* = @intCast(3 + next() % 8);
        for (word[0..len.*]) |*c| c.* = @intCast('a' + next() % 26);
    }
    // the text: word k is picked about 1/k as often as word 1
    var text: std.ArrayList(u8) = try .initCapacity(gpa, 1 << 20);
    defer text.deinit(gpa);
    for (0..@intCast(n)) |_| {
        const bits: u6 = @intCast(next() % 19);
        const k = next() & ((@as(u64, 1) << bits) - 1);
        try text.appendSlice(gpa, words[k][0..lens[k]]);
        try text.append(gpa, ' ');
    }
    var counts: std.StringHashMapUnmanaged(i64) = .empty;
    defer counts.deinit(gpa);
    var total: i64 = 0;
    var it = std.mem.splitScalar(u8, text.items, ' ');
    while (it.next()) |word| {
        if (word.len == 0) continue; // after the last space
        const e = try counts.getOrPut(gpa, word);
        if (!e.found_existing) e.value_ptr.* = 0;
        e.value_ptr.* += 1;
        total += 1;
    }
    const all = try gpa.alloc(Entry, counts.count());
    defer gpa.free(all);
    var m: usize = 0;
    var entries = counts.iterator();
    while (entries.next()) |e| : (m += 1) all[m] = .{ .word = e.key_ptr.*, .count = e.value_ptr.* };
    std.mem.sortUnstable(Entry, all, {}, byCount);

    var buf: [4096]u8 = undefined;
    var w = std.Io.File.stdout().writer(init.io, &buf);
    const out = &w.interface;
    try out.print("{d} bytes, {d} words, {d} distinct\n", .{ text.items.len, total, all.len });
    for (all[0..@min(20, all.len)]) |e| try out.print("{s} {d}\n", .{ e.word, e.count });
    try out.flush();
}
