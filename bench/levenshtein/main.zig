// levenshtein: edit distances between many pairs of strings, each a random string of 64 to 191
// letters and a copy with random substitutions, deletions and insertions, by the dynamic program
// over one row; prints the number of pairs, the sum and the largest of the distances, and a checksum
// of them all
const std = @import("std");

fn distance(a: []const u8, b: []const u8, row: []u32) u32 {
    for (row[0 .. b.len + 1], 0..) |*r, j| r.* = @intCast(j);
    for (a, 1..) |ca, i| {
        var diag = row[0];
        row[0] = @intCast(i);
        for (b, 1..) |cb, j| {
            const up = row[j];
            row[j] = @min(diag + @intFromBool(ca != cb), up + 1, row[j - 1] + 1);
            diag = up;
        }
    }
    return row[b.len];
}

var x: u64 = 88172645463325252;

fn next() u64 {
    x ^= x << 13;
    x ^= x >> 7;
    x ^= x << 17;
    return x;
}

pub fn main(init: std.process.Init) !void {
    var args = init.minimal.args.iterate();
    _ = args.skip();
    const pairs: usize = if (args.next()) |s| try std.fmt.parseInt(usize, s, 10) else 40000;
    const letters = "abcdefgh";
    var a: [192]u8 = undefined;
    var b: [384]u8 = undefined;
    var row: [385]u32 = undefined;
    var total: u64 = 0;
    var check: u64 = 0;
    var most: u32 = 0;
    for (0..pairs) |_| {
        const la = 64 + next() % 128;
        for (a[0..la]) |*c| c.* = letters[next() % 8];
        // b: a with about one letter in 8 changed, one in 16 dropped and one in 16 inserted
        var lb: usize = 0;
        for (a[0..la]) |c| {
            const r = next() % 16;
            if (r == 0) continue;
            if (r == 1) {
                b[lb] = letters[next() % 8];
                lb += 1;
            }
            b[lb] = if (r == 2 or r == 3) letters[next() % 8] else c;
            lb += 1;
        }
        const d = distance(a[0..la], b[0..lb], &row);
        total += d;
        most = @max(most, d);
        check = check *% 31 +% d;
    }
    var buf: [256]u8 = undefined;
    var fw = std.Io.File.stdout().writer(init.io, &buf);
    const w = &fw.interface;
    try w.print("{d} pairs, total distance {d}, largest {d}\n", .{ pairs, total, most });
    try w.print("checksum {d}\n", .{check});
    try w.flush();
}
