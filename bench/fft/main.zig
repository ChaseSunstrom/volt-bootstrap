// fft: an iterative radix-2 FFT over complex doubles: a random signal of n points (a power of two)
// taken to its spectrum and back sixteen times, then checked against the original; prints the
// spectrum's mean energy and two of its points, and the signal's sum. The twiddles come from
// half-angle formulas (sqrt only, which every language rounds the same) and products, not from sin
// and cos. Zig uses std.math.Complex(f64)
const std = @import("std");
const Complex = std.math.Complex(f64);

// e^(-2 pi i j / n) for j < n / 2: the table for each len = 2, 4, ... n from the one before, its even
// entries the old ones and its odd ones those times e^(-2 pi i / len)
fn twiddles(tw: []Complex, n: usize) void {
    tw[0] = Complex.init(1, 0);
    var c: f64 = 0; // cos and sin of 2 pi / len
    var s: f64 = 1;
    var len: usize = 4;
    while (len <= n) : (len *= 2) {
        if (len > 4) {
            c = @sqrt((1 + c) / 2);
            s = s / (2 * c);
        }
        const w = Complex.init(c, -s);
        var j = len / 4;
        while (j > 0) {
            j -= 1;
            tw[2 * j + 1] = tw[j].mul(w);
            tw[2 * j] = tw[j];
        }
    }
}

fn fft(a: []Complex, tw: []const Complex) void {
    const n = a.len;
    var j: usize = 0;
    for (1..n) |i| {
        var bit = n >> 1;
        while (j & bit != 0) : (bit >>= 1) j ^= bit;
        j ^= bit;
        if (i < j) std.mem.swap(Complex, &a[i], &a[j]);
    }
    var len: usize = 2;
    while (len <= n) : (len *= 2) {
        const half = len / 2;
        const step = n / len;
        var i: usize = 0;
        while (i < n) : (i += len) {
            for (a[i..][0..half], a[i + half ..][0..half], 0..) |*u, *v, k| {
                const t = v.mul(tw[k * step]);
                v.* = u.sub(t);
                u.* = u.add(t);
            }
        }
    }
}

var x: u64 = 88172645463325252;

fn next() u64 {
    x ^= x << 13;
    x ^= x >> 7;
    x ^= x << 17;
    return x;
}

fn unit() f64 {
    return @as(f64, @floatFromInt(next() >> 11)) / 9007199254740992.0 - 0.5;
}

pub fn main(init: std.process.Init) !void {
    var args = init.minimal.args.iterate();
    _ = args.skip();
    const n: usize = if (args.next()) |s| try std.fmt.parseInt(usize, s, 10) else 1048576;
    const gpa = init.gpa;
    const signal = try gpa.alloc(Complex, n);
    defer gpa.free(signal);
    for (signal) |*v| {
        const re = unit();
        v.* = Complex.init(re, unit());
    }
    const a = try gpa.dupe(Complex, signal);
    defer gpa.free(a);
    const tw = try gpa.alloc(Complex, n / 2);
    defer gpa.free(tw);
    twiddles(tw, n);
    const inv = try gpa.alloc(Complex, n / 2);
    defer gpa.free(inv);
    for (inv, tw) |*v, w| v.* = w.conjugate();
    const scale = 1.0 / @as(f64, @floatFromInt(n));
    var energy: f64 = 0;
    var low = Complex.init(0, 0);
    var mid = Complex.init(0, 0);
    for (0..16) |round| {
        fft(a, tw);
        if (round == 0) {
            for (a) |v| energy += v.re * v.re + v.im * v.im;
            low = a[1];
            mid = a[n / 3];
        }
        fft(a, inv);
        for (a) |*v| v.* = Complex.init(v.re * scale, v.im * scale);
    }
    var err: f64 = 0;
    var sum: f64 = 0;
    for (a, signal) |v, s| {
        err = @max(err, @abs(v.re - s.re) + @abs(v.im - s.im));
        sum += v.re + v.im;
    }
    if (err > 1e-9) {
        std.debug.print("round trips drifted by {d}\n", .{err});
        std.process.exit(1);
    }
    var buf: [512]u8 = undefined;
    var fw = std.Io.File.stdout().writer(init.io, &buf);
    const w = &fw.interface;
    try w.print("{d} points, mean energy {d:.6}\n", .{ n, energy / @as(f64, @floatFromInt(n)) });
    try w.print("X[1] = ({d:.6}, {d:.6}), X[n/3] = ({d:.6}, {d:.6})\n", .{ low.re, low.im, mid.re, mid.im });
    try w.print("signal sum after 16 round trips {d:.6}\n", .{sum});
    try w.flush();
}
