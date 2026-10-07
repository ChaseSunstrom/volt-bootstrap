// print: half a million doubles in [1, 2) as the shortest text that reads back as the same value
// (Zig's {d} for f64), then half a million integers, a line each
const std = @import("std");

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
    const n: u64 = if (args.next()) |s| try std.fmt.parseInt(u64, s, 10) else 500000;
    var buf: [65536]u8 = undefined;
    var fw = std.Io.File.stdout().writer(init.io, &buf);
    const w = &fw.interface;
    for (0..n) |_| {
        const v = 1.0 + @as(f64, @floatFromInt(next() >> 12)) / 4503599627370496.0;
        try w.print("{d}\n", .{v});
    }
    for (0..n) |_| try w.print("{d}\n", .{next() >> 1});
    try w.flush();
}
