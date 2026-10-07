// vec_grow: growing arrays one push at a time (no reserve), then summing them, many times over
const std = @import("std");

pub fn main(init: std.process.Init) !void {
    var args = init.minimal.args.iterate();
    _ = args.skip();
    const n = if (args.next()) |a| try std.fmt.parseInt(i64, a, 10) else 20000000;
    const gpa = init.gpa;
    var total: u64 = 0;
    for (0..10) |round| {
        var xs: std.ArrayList(i64) = .empty;
        defer xs.deinit(gpa);
        var i: i64 = 0;
        while (i < n) : (i += 1) try xs.append(gpa, i * 3 + @as(i64, @intCast(round)));
        for (xs.items) |x| total +%= @bitCast(x);
    }
    var buf: [256]u8 = undefined;
    var w = std.Io.File.stdout().writer(init.io, &buf);
    try w.interface.print("{d}\n", .{total});
    try w.interface.flush();
}
