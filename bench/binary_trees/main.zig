// binary-trees (the Benchmarks Game): allocate and walk many perfect binary trees, then free them
const std = @import("std");

const Node = struct { left: ?*Node, right: ?*Node };

fn make(gpa: std.mem.Allocator, depth: i32) !*Node {
    const n = try gpa.create(Node);
    if (depth > 0) {
        n.* = .{ .left = try make(gpa, depth - 1), .right = try make(gpa, depth - 1) };
    } else {
        n.* = .{ .left = null, .right = null };
    }
    return n;
}

fn check(n: *const Node) i32 {
    return 1 + if (n.left) |l| check(l) + check(n.right.?) else 0;
}

fn drop(gpa: std.mem.Allocator, n: *Node) void {
    if (n.left) |l| {
        drop(gpa, l);
        drop(gpa, n.right.?);
    }
    gpa.destroy(n);
}

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    var args = init.minimal.args.iterate();
    _ = args.skip();
    const max = @max(6, if (args.next()) |s| try std.fmt.parseInt(i32, s, 10) else 18);
    var buf: [4096]u8 = undefined;
    var fw = std.Io.File.stdout().writer(init.io, &buf);
    const w = &fw.interface;
    const stretch = try make(gpa, max + 1);
    try w.print("stretch tree of depth {d}\t check: {d}\n", .{ max + 1, check(stretch) });
    drop(gpa, stretch);
    const long_lived = try make(gpa, max);
    var d: i32 = 4;
    while (d <= max) : (d += 2) {
        const iters = @as(i32, 1) << @intCast(max - d + 4);
        var sum: i32 = 0;
        for (0..@intCast(iters)) |_| {
            const t = try make(gpa, d);
            sum += check(t);
            drop(gpa, t);
        }
        try w.print("{d}\t trees of depth {d}\t check: {d}\n", .{ iters, d, sum });
    }
    try w.print("long lived tree of depth {d}\t check: {d}\n", .{ max, check(long_lived) });
    drop(gpa, long_lived);
    try w.flush();
}
