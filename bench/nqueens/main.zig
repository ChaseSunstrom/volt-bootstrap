// nqueens: counts the placements of n queens on an n x n board with bitboards and recursion: the
// columns and both diagonals under attack are bit masks, the free squares a mask that's peeled a bit
// at a time
const std = @import("std");

fn solve(all: u32, cols: u32, left: u32, right: u32) u64 {
    if (cols == all) return 1;
    var count: u64 = 0;
    var free = all & ~(cols | left | right);
    while (free != 0) {
        const bit = free & (0 -% free);
        free ^= bit;
        count += solve(all, cols | bit, (left | bit) << 1, (right | bit) >> 1);
    }
    return count;
}

pub fn main(init: std.process.Init) !void {
    var args = init.minimal.args.iterate();
    _ = args.skip();
    const n = if (args.next()) |a| try std.fmt.parseInt(u5, a, 10) else 15;
    const all = (@as(u32, 1) << n) - 1;
    var buf: [256]u8 = undefined;
    var w = std.Io.File.stdout().writer(init.io, &buf);
    try w.interface.print("{d} queens: {d}\n", .{ n, solve(all, 0, 0, 0) });
    try w.interface.flush();
}
