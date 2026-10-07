// hash map churn: insert n pseudo-random keys, look each up plus as many misses, remove half (std.AutoHashMapUnmanaged)
const std = @import("std");

fn lcg(x: u64) u64 {
    return x *% 6364136223846793005 +% 1442695040888963407;
}

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    var args = init.minimal.args.iterate();
    _ = args.skip();
    const n: u64 = if (args.next()) |a| try std.fmt.parseInt(u64, a, 10) else 5000000;
    var m: std.AutoHashMapUnmanaged(u64, u64) = .empty;
    defer m.deinit(gpa);
    var x: u64 = 42;
    for (0..n) |i| {
        x = lcg(x);
        try m.put(gpa, x >> 16, i);
    }
    var sum: u64 = 0;
    var found: u64 = 0;
    x = 42;
    for (0..n) |_| {
        x = lcg(x);
        if (m.get(x >> 16)) |v| {
            sum += v;
            found += 1;
        }
        if (m.contains((x >> 16) + 1)) found += 1;
    }
    x = 42;
    var removed: u64 = 0;
    var i: u64 = 0;
    while (i < n) : (i += 2) {
        x = lcg(x);
        if (m.remove(x >> 16)) removed += 1;
        x = lcg(x);
    }
    var buf: [128]u8 = undefined;
    var w = std.Io.File.stdout().writer(init.io, &buf);
    try w.interface.print("{d} {d} {d} {d}\n", .{ m.count(), found, sum, removed });
    try w.interface.flush();
}
