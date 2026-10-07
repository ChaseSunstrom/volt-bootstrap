// lru_cache: an LRU cache of 100000 int keys to owned strings under n skewed get/put operations
// (a miss puts the value); Zig keeps the nodes in an ArrayList linked by index into a recency list,
// found through a std.array_hash_map.Auto from key to index, with allocated value bytes
const std = @import("std");
const Allocator = std.mem.Allocator;

var x: u64 = 88172645463325252;

fn next() u64 {
    x ^= x << 13;
    x ^= x >> 7;
    x ^= x << 17;
    return x;
}

const Node = struct {
    key: u64,
    val: []u8,
    prev: u32, // recency: nodes[0] is the sentinel, and its next is the most recent
    next: u32,
};

const Lru = struct {
    gpa: Allocator,
    nodes: std.ArrayList(Node),
    index: std.array_hash_map.Auto(u64, u32), // no tombstones to pile up as keys come and go
    cap: usize,

    fn init(gpa: Allocator, cap: usize) !Lru {
        var c: Lru = .{ .gpa = gpa, .nodes = try .initCapacity(gpa, cap + 1), .index = .empty, .cap = cap };
        try c.index.ensureTotalCapacity(gpa, cap);
        c.nodes.appendAssumeCapacity(.{ .key = 0, .val = &.{}, .prev = 0, .next = 0 });
        return c;
    }

    fn deinit(c: *Lru) void {
        for (c.nodes.items) |n| c.gpa.free(n.val);
        c.nodes.deinit(c.gpa);
        c.index.deinit(c.gpa);
    }

    fn unlink(c: *Lru, i: u32) void {
        const n = c.nodes.items;
        n[n[i].prev].next = n[i].next;
        n[n[i].next].prev = n[i].prev;
    }

    fn pushFront(c: *Lru, i: u32) void {
        const n = c.nodes.items;
        n[i].prev = 0;
        n[i].next = n[0].next;
        n[n[0].next].prev = i;
        n[0].next = i;
    }

    // the value for key (marked most recent), or null
    fn get(c: *Lru, key: u64) ?[]const u8 {
        const i = c.index.get(key) orelse return null;
        c.unlink(i);
        c.pushFront(i);
        return c.nodes.items[i].val;
    }

    // set key to val (taking it), evicting the least recent key when full
    fn put(c: *Lru, key: u64, val: []u8) !void {
        if (c.index.get(key)) |i| {
            c.gpa.free(c.nodes.items[i].val);
            c.nodes.items[i].val = val;
            c.unlink(i);
            c.pushFront(i);
            return;
        }
        var i: u32 = undefined;
        if (c.index.count() == c.cap) {
            // the least recent node takes the new key
            i = c.nodes.items[0].prev;
            c.unlink(i);
            _ = c.index.swapRemove(c.nodes.items[i].key);
            c.gpa.free(c.nodes.items[i].val);
            c.nodes.items[i].key = key;
            c.nodes.items[i].val = val;
        } else {
            i = @intCast(c.nodes.items.len);
            try c.nodes.append(c.gpa, .{ .key = key, .val = val, .prev = 0, .next = 0 });
        }
        try c.index.put(c.gpa, key, i);
        c.pushFront(i);
    }
};

const PATTERN = "abcdefghijklmnopqrstuvwxyzabcdefghijklmnopqrstuvwxyzabcdefghijklmnop";

// the value stored for key at step i: 8 to 32 letters
fn makeValue(gpa: Allocator, key: u64, i: u64) ![]u8 {
    return gpa.dupe(u8, PATTERN[key % 26 ..][0 .. 8 + (key + i) % 25]);
}

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    var args = init.minimal.args.iterate();
    _ = args.skip();
    const n: u64 = if (args.next()) |s| try std.fmt.parseInt(u64, s, 10) else 20000000;
    var cache = try Lru.init(gpa, 100000);
    defer cache.deinit();
    var hits: u64 = 0;
    var misses: u64 = 0;
    var total: usize = 0;
    for (0..n) |i| {
        const r = next();
        // three in four keys come from a hot set a little bigger than the cache
        const key = if (r % 4 != 0) next() % 120000 else next() % 1000000;
        if ((r >> 8) % 10 == 0) {
            try cache.put(key, try makeValue(gpa, key, i));
            continue;
        }
        if (cache.get(key)) |v| {
            hits += 1;
            total += v.len;
        } else {
            misses += 1;
            try cache.put(key, try makeValue(gpa, key, i));
        }
    }
    var buf: [256]u8 = undefined;
    var fw = std.Io.File.stdout().writer(init.io, &buf);
    try fw.interface.print("{d} hits, {d} misses, {d} total, {d} cached\n", .{ hits, misses, total, cache.index.count() });
    try fw.interface.flush();
}
