// fannkuch-redux (the Benchmarks Game): pancake flips over every permutation of 1..n
const std = @import("std");

pub fn main(init: std.process.Init) !void {
    var args = init.minimal.args.iterate();
    _ = args.skip();
    const n: usize = if (args.next()) |a| try std.fmt.parseInt(usize, a, 10) else 11;
    var perm1: [16]usize = undefined;
    for (&perm1, 0..) |*p, i| p.* = i;
    var count: [16]usize = @splat(0);
    var max_flips: i32 = 0;
    var checksum: i32 = 0;
    var perm_count: u64 = 0;
    var r = n;
    while (true) : (perm_count += 1) {
        while (r != 1) : (r -= 1) count[r - 1] = r;
        var perm = perm1;
        var flips: i32 = 0;
        while (perm[0] != 0) : (flips += 1) std.mem.reverse(usize, perm[0 .. perm[0] + 1]);
        max_flips = @max(max_flips, flips);
        checksum += if (perm_count % 2 == 0) flips else -flips;
        while (true) : (r += 1) {
            if (r == n) {
                var buf: [256]u8 = undefined;
                var w = std.Io.File.stdout().writer(init.io, &buf);
                try w.interface.print("{d}\nPfannkuchen({d}) = {d}\n", .{ checksum, n, max_flips });
                try w.interface.flush();
                return;
            }
            std.mem.rotate(usize, perm1[0 .. r + 1], 1);
            count[r] -= 1;
            if (count[r] > 0) break;
        }
    }
}
