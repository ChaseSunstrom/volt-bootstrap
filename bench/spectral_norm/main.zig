// spectral-norm (the Benchmarks Game): the largest eigenvalue of an infinite matrix, by power iteration
const std = @import("std");

fn a(i: usize, j: usize) f64 {
    return 1.0 / @as(f64, @floatFromInt((i + j) * (i + j + 1) / 2 + i + 1));
}

fn times(v: []const f64, out: []f64) void {
    for (out, 0..) |*o, i| {
        var s: f64 = 0;
        for (v, 0..) |x, j| s += a(i, j) * x;
        o.* = s;
    }
}

fn timesT(v: []const f64, out: []f64) void {
    for (out, 0..) |*o, i| {
        var s: f64 = 0;
        for (v, 0..) |x, j| s += a(j, i) * x;
        o.* = s;
    }
}

fn ata(v: []const f64, out: []f64, tmp: []f64) void {
    times(v, tmp);
    timesT(tmp, out);
}

pub fn main(init: std.process.Init) !void {
    var args = init.minimal.args.iterate();
    _ = args.skip();
    const n: usize = if (args.next()) |arg| try std.fmt.parseInt(usize, arg, 10) else 5500;
    const gpa = init.gpa;
    const u = try gpa.alloc(f64, n);
    defer gpa.free(u);
    const v = try gpa.alloc(f64, n);
    defer gpa.free(v);
    const tmp = try gpa.alloc(f64, n);
    defer gpa.free(tmp);
    @memset(u, 1);
    for (0..10) |_| {
        ata(u, v, tmp);
        ata(v, u, tmp);
    }
    var vbv: f64 = 0;
    var vv: f64 = 0;
    for (u, v) |x, y| {
        vbv += x * y;
        vv += y * y;
    }
    var buf: [64]u8 = undefined;
    var w = std.Io.File.stdout().writer(init.io, &buf);
    try w.interface.print("{d:.9}\n", .{@sqrt(vbv / vv)});
    try w.interface.flush();
}
