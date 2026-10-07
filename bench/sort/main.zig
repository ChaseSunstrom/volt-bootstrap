// sort: n pseudo-random 64-bit integers with std.mem.sort, which is stable (Volt's sort is stable too)
const std = @import("std");

pub fn main(init: std.process.Init) !void {
    var args = init.minimal.args.iterate();
    _ = args.skip();
    const n = if (args.next()) |a| try std.fmt.parseInt(usize, a, 10) else 5000000;
    const xs = try init.gpa.alloc(i64, n);
    defer init.gpa.free(xs);
    var s: u64 = 7;
    for (xs) |*x| {
        s = s *% 6364136223846793005 +% 1442695040888963407;
        x.* = @rem(@as(i64, @intCast(s >> 1)), 1000000007);
    }
    std.mem.sort(i64, xs, {}, std.sort.asc(i64));
    var check: u64 = 0;
    for (xs) |x| check = check *% 31 +% @as(u64, @bitCast(x));
    var buf: [256]u8 = undefined;
    var w = std.Io.File.stdout().writer(init.io, &buf);
    try w.interface.print("{d} {d} {d}\n", .{ xs[0], xs[n - 1], check });
    try w.interface.flush();
}
