// heap: a binary min-heap used for two element types: n random integers, then n tasks ordered by (priority, id); Zig uses the generic std.PriorityQueue
const std = @import("std");

var seed: u64 = 88172645463325252;

fn next() u64 {
    seed ^= seed << 13;
    seed ^= seed >> 7;
    seed ^= seed << 17;
    return seed;
}

const Task = struct { priority: u32, id: u32 };

fn orderU64(_: void, a: u64, b: u64) std.math.Order {
    return std.math.order(a, b);
}

/// by priority, then id
fn orderTask(_: void, a: Task, b: Task) std.math.Order {
    return std.math.order(a.priority, b.priority).differ() orelse std.math.order(a.id, b.id);
}

pub fn main(init: std.process.Init) !void {
    var args = init.minimal.args.iterate();
    _ = args.skip();
    const n: usize = if (args.next()) |a| try std.fmt.parseInt(usize, a, 10) else 3000000;
    const gpa = init.gpa;

    var ints: std.PriorityQueue(u64, void, orderU64) = .empty;
    defer ints.deinit(gpa);
    for (0..n) |_| try ints.push(gpa, next() >> 16);
    var sum: u64 = 0;
    var prev: u64 = 0;
    var sorted: u64 = 1;
    while (ints.pop()) |v| {
        sorted &= @intFromBool(prev <= v);
        prev = v;
        sum = sum *% 31 +% v;
    }

    var tasks: std.PriorityQueue(Task, void, orderTask) = .empty;
    defer tasks.deinit(gpa);
    for (0..n) |i| try tasks.push(gpa, .{ .priority = @intCast(next() % 1000), .id = @intCast(i) });
    var order: u64 = 0;
    while (tasks.pop()) |t| order = order *% 31 +% t.id;

    var buf: [256]u8 = undefined;
    var w = std.Io.File.stdout().writer(init.io, &buf);
    try w.interface.print("{d} {d} {d}\n", .{ sorted, sum, order });
    try w.interface.flush();
}
