// life: Conway's game of life on an n x n grid that wraps at the edges (a torus), a byte per cell,
// from a random start for 400 generations; prints the population every 100 generations and a
// checksum of the last grid
const std = @import("std");

var x: u64 = 88172645463325252;

fn next() u64 {
    x ^= x << 13;
    x ^= x >> 7;
    x ^= x << 17;
    return x;
}

fn population(cells: []const u8) usize {
    var count: usize = 0;
    for (cells) |c| count += c;
    return count;
}

fn step(cur: []const u8, out: []u8, n: usize) void {
    for (0..n) |y| {
        const up = cur[(if (y == 0) n - 1 else y - 1) * n ..][0..n];
        const row = cur[y * n ..][0..n];
        const down = cur[(if (y == n - 1) 0 else y + 1) * n ..][0..n];
        for (out[y * n ..][0..n], 0..) |*cell, i| {
            const l = if (i == 0) n - 1 else i - 1;
            const r = if (i == n - 1) 0 else i + 1;
            const around = up[l] + up[i] + up[r] + row[l] + row[r] + down[l] + down[i] + down[r];
            cell.* = @intFromBool(around == 3 or (around == 2 and row[i] == 1));
        }
    }
}

pub fn main(init: std.process.Init) !void {
    var args = init.minimal.args.iterate();
    _ = args.skip();
    const n: usize = if (args.next()) |s| try std.fmt.parseInt(usize, s, 10) else 1024;
    const gpa = init.gpa;
    var a = try gpa.alloc(u8, n * n);
    defer gpa.free(a);
    var b = try gpa.alloc(u8, n * n);
    defer gpa.free(b);
    for (a) |*c| c.* = @intFromBool(next() % 3 == 0);
    var buf: [256]u8 = undefined;
    var fw = std.Io.File.stdout().writer(init.io, &buf);
    const w = &fw.interface;
    for (0..401) |gen| {
        if (gen % 100 == 0) try w.print("generation {d}: {d} alive\n", .{ gen, population(a) });
        if (gen == 400) break;
        step(a, b, n);
        std.mem.swap([]u8, &a, &b);
    }
    var check: u64 = 14695981039346656037;
    for (a) |c| check = (check ^ c) *% 1099511628211;
    try w.print("checksum {d}\n", .{check});
    try w.flush();
}
