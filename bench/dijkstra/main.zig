// dijkstra: shortest paths over an n x n grid whose edges have random weights, from two corners, with a binary heap of (distance, node) and lazy deletion
const std = @import("std");
const Allocator = std.mem.Allocator;

const Item = struct { dist: u64, node: u32 };

fn order(_: void, a: Item, b: Item) std.math.Order {
    return std.math.order(a.dist, b.dist).differ() orelse std.math.order(a.node, b.node);
}

const Heap = std.PriorityQueue(Item, void, order);

/// distances from src to every node; weight[node * 4 + d] is the cost of leaving node in direction d
fn shortest(gpa: Allocator, n: usize, weight: []const u32, src: u32, dist: []u64, relaxed: *u64) !void {
    @memset(dist, std.math.maxInt(u64));
    var heap: Heap = .empty;
    defer heap.deinit(gpa);
    try heap.ensureTotalCapacity(gpa, 1024);
    dist[src] = 0;
    try heap.push(gpa, .{ .dist = 0, .node = src });
    while (heap.pop()) |cur| {
        if (cur.dist > dist[cur.node]) continue;
        const x = cur.node % n;
        const y = cur.node / n;
        for (0..4) |d| {
            var nx = x;
            var ny = y;
            switch (d) {
                0 => if (x + 1 < n) {
                    nx = x + 1;
                } else continue,
                1 => if (x > 0) {
                    nx = x - 1;
                } else continue,
                2 => if (y + 1 < n) {
                    ny = y + 1;
                } else continue,
                else => if (y > 0) {
                    ny = y - 1;
                } else continue,
            }
            const to = ny * n + nx;
            const nd = cur.dist + weight[cur.node * 4 + d];
            if (nd < dist[to]) {
                dist[to] = nd;
                relaxed.* += 1;
                try heap.push(gpa, .{ .dist = nd, .node = @intCast(to) });
            }
        }
    }
}

pub fn main(init: std.process.Init) !void {
    var args = init.minimal.args.iterate();
    _ = args.skip();
    const n: usize = if (args.next()) |a| try std.fmt.parseInt(usize, a, 10) else 1500;
    const gpa = init.gpa;
    const count = n * n;
    const weight = try gpa.alloc(u32, count * 4);
    defer gpa.free(weight);
    var seed: u64 = 88172645463325252;
    for (weight) |*wt| {
        seed ^= seed << 13;
        seed ^= seed >> 7;
        seed ^= seed << 17;
        wt.* = @intCast(seed % 100 + 1);
    }
    const dist = try gpa.alloc(u64, count);
    defer gpa.free(dist);
    var relaxed: u64 = 0;
    const sources = [2]u32{ 0, @intCast(count - 1) };
    var buf: [256]u8 = undefined;
    var w = std.Io.File.stdout().writer(init.io, &buf);
    const out = &w.interface;
    for (0..2) |s| {
        try shortest(gpa, n, weight, sources[s], dist, &relaxed);
        var sum: u64 = 0;
        var far: u64 = 0;
        for (dist) |d| {
            sum += d;
            far = @max(far, d);
        }
        try out.print("from {d}: corner {d}, farthest {d}, sum {d}\n", .{ sources[s], dist[sources[1 - s]], far, sum });
    }
    try out.print("relaxed {d}\n", .{relaxed});
    try out.flush();
}
