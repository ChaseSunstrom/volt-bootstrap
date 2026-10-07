// closures: a map / filter / fold pipeline over an array, many rounds; Zig passes context structs as anytype
const std = @import("std");

fn pipeline(xs: []const i64, f: anytype, keep: anytype) i64 {
    var sum: i64 = 0;
    for (xs) |x| {
        const y = f.call(x);
        if (keep.call(y)) sum += y;
    }
    return sum;
}

const Scale = struct {
    factor: i64,
    fn call(s: Scale, x: i64) i64 {
        return x * s.factor + 1;
    }
};

const Below = struct {
    limit: i64,
    fn call(b: Below, y: i64) bool {
        return @rem(y, 3) != 0 and y < b.limit;
    }
};

pub fn main(init: std.process.Init) !void {
    var args = init.minimal.args.iterate();
    _ = args.skip();
    const rounds: i64 = if (args.next()) |a| try std.fmt.parseInt(i64, a, 10) else 1000;
    const xs = try init.gpa.alloc(i64, 1000000);
    defer init.gpa.free(xs);
    for (xs, 0..) |*x, i| x.* = @intCast(i % 1000);
    var total: i64 = 0;
    var r: i64 = 0;
    while (r < rounds) : (r += 1) {
        total += pipeline(xs, Scale{ .factor = @rem(r, 7) + 2 }, Below{ .limit = 5000 - r });
    }
    var buf: [64]u8 = undefined;
    var w = std.Io.File.stdout().writer(init.io, &buf);
    try w.interface.print("{d}\n", .{total});
    try w.interface.flush();
}
