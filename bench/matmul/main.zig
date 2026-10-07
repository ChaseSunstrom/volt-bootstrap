// matmul: two n×n matrices of doubles multiplied in i, k, j order (row by row, cache-friendly)
const std = @import("std");

pub fn main(init: std.process.Init) !void {
    var args = init.minimal.args.iterate();
    _ = args.skip();
    const n: usize = if (args.next()) |s| try std.fmt.parseInt(usize, s, 10) else 1600;
    const nf: f64 = @floatFromInt(n);
    const gpa = init.gpa;
    const a = try gpa.alloc(f64, n * n);
    defer gpa.free(a);
    const b = try gpa.alloc(f64, n * n);
    defer gpa.free(b);
    const c = try gpa.alloc(f64, n * n);
    defer gpa.free(c);
    @memset(c, 0);
    for (0..n) |i| {
        for (0..n) |j| {
            a[i * n + j] = (@as(f64, @floatFromInt(i)) - @as(f64, @floatFromInt(j))) / nf;
            b[i * n + j] = @as(f64, @floatFromInt(i + 2 * j + 1)) / nf;
        }
    }
    for (0..n) |i| {
        const row = c[i * n ..][0..n];
        for (0..n) |k| {
            const aik = a[i * n + k];
            for (row, b[k * n ..][0..n]) |*cij, bkj| cij.* += aik * bkj;
        }
    }
    var trace: f64 = 0;
    var sum: f64 = 0;
    for (0..n) |i| trace += c[i * n + i];
    for (c) |x| sum += x;
    var buf: [256]u8 = undefined;
    var w = std.Io.File.stdout().writer(init.io, &buf);
    try w.interface.print("{d:.6} {d:.6}\n", .{ trace, sum });
    try w.interface.flush();
}
