// mandelbrot (after the Benchmarks Game): how many points of an n x n grid stay in the set for 50 steps
const std = @import("std");

pub fn main(init: std.process.Init) !void {
    var args = init.minimal.args.iterate();
    _ = args.skip();
    const n = if (args.next()) |a| try std.fmt.parseInt(i32, a, 10) else 4000;
    const nf: f64 = @floatFromInt(n);
    var inside: i64 = 0;
    var y: i32 = 0;
    while (y < n) : (y += 1) {
        const ci = 2.0 * @as(f64, @floatFromInt(y)) / nf - 1.0;
        var x: i32 = 0;
        while (x < n) : (x += 1) {
            const cr = 2.0 * @as(f64, @floatFromInt(x)) / nf - 1.5;
            var zr: f64 = 0;
            var zi: f64 = 0;
            var tr: f64 = 0;
            var ti: f64 = 0;
            var i: i32 = 0;
            while (i < 50 and tr + ti <= 4.0) : (i += 1) {
                zi = 2.0 * zr * zi + ci;
                zr = tr - ti + cr;
                tr = zr * zr;
                ti = zi * zi;
            }
            if (tr + ti <= 4.0) inside += 1;
        }
    }
    var buf: [256]u8 = undefined;
    var w = std.Io.File.stdout().writer(init.io, &buf);
    try w.interface.print("{d}\n", .{inside});
    try w.interface.flush();
}
