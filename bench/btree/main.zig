// btree: an ordered map from u64 to u64 under random inserts (some overwriting), lookups (two in five
// of them hits) and range scans of 100 entries from a random key; prints the size, the hits and a
// checksum of what the lookups and scans saw. Zig's standard library has no ordered map, so this is a
// B-tree generic over its key and value types (31 keys a node, splitting full nodes on the way down)
const std = @import("std");
const Allocator = std.mem.Allocator;

fn BTree(comptime K: type, comptime V: type) type {
    return struct {
        const Self = @This();
        const MAX = 31; // keys in a node; a full one splits into two of 15 around its middle key
        const HALF = MAX / 2;

        const Node = struct {
            n: usize = 0,
            leaf: bool,
            keys: [MAX]K = undefined,
            vals: [MAX]V = undefined,
            kids: [MAX + 1]*Node = undefined,

            // the first key not below k
            fn lower(x: *const Node, k: K) usize {
                var i: usize = 0;
                while (i < x.n and x.keys[i] < k) i += 1;
                return i;
            }
        };

        root: *Node,
        len: usize = 0,

        fn init(gpa: Allocator) !Self {
            const root = try gpa.create(Node);
            root.* = .{ .leaf = true };
            return .{ .root = root };
        }

        fn deinit(self: *Self, gpa: Allocator) void {
            freeNode(gpa, self.root);
        }

        fn freeNode(gpa: Allocator, x: *Node) void {
            if (!x.leaf) {
                for (x.kids[0 .. x.n + 1]) |kid| freeNode(gpa, kid);
            }
            gpa.destroy(x);
        }

        // x.kids[i] is full: its upper half moves to a new node after it, and its middle key up into x
        fn splitChild(gpa: Allocator, x: *Node, i: usize) !void {
            const y = x.kids[i];
            const z = try gpa.create(Node);
            z.* = .{ .leaf = y.leaf, .n = HALF };
            @memcpy(z.keys[0..HALF], y.keys[HALF + 1 ..]);
            @memcpy(z.vals[0..HALF], y.vals[HALF + 1 ..]);
            if (!y.leaf) @memcpy(z.kids[0 .. HALF + 1], y.kids[HALF + 1 ..]);
            y.n = HALF;
            std.mem.copyBackwards(*Node, x.kids[i + 2 .. x.n + 2], x.kids[i + 1 .. x.n + 1]);
            x.kids[i + 1] = z;
            std.mem.copyBackwards(K, x.keys[i + 1 .. x.n + 1], x.keys[i..x.n]);
            std.mem.copyBackwards(V, x.vals[i + 1 .. x.n + 1], x.vals[i..x.n]);
            x.keys[i] = y.keys[HALF];
            x.vals[i] = y.vals[HALF];
            x.n += 1;
        }

        fn put(self: *Self, gpa: Allocator, k: K, v: V) !void {
            if (self.root.n == MAX) {
                const r = try gpa.create(Node);
                r.* = .{ .leaf = false };
                r.kids[0] = self.root;
                self.root = r;
                try splitChild(gpa, r, 0);
            }
            var x = self.root;
            while (true) {
                var i = x.lower(k);
                if (i < x.n and x.keys[i] == k) {
                    x.vals[i] = v;
                    return;
                }
                if (x.leaf) {
                    std.mem.copyBackwards(K, x.keys[i + 1 .. x.n + 1], x.keys[i..x.n]);
                    std.mem.copyBackwards(V, x.vals[i + 1 .. x.n + 1], x.vals[i..x.n]);
                    x.keys[i] = k;
                    x.vals[i] = v;
                    x.n += 1;
                    self.len += 1;
                    return;
                }
                if (x.kids[i].n == MAX) {
                    try splitChild(gpa, x, i);
                    if (k == x.keys[i]) {
                        x.vals[i] = v;
                        return;
                    }
                    if (k > x.keys[i]) i += 1;
                }
                x = x.kids[i];
            }
        }

        fn get(self: *const Self, k: K) ?*V {
            var x = self.root;
            while (true) {
                const i = x.lower(k);
                if (i < x.n and x.keys[i] == k) return &x.vals[i];
                if (x.leaf) return null;
                x = x.kids[i];
            }
        }

        // calls ctx.visit on the entries from the first key not below lo, in order, while left.* > 0
        fn scan(x: *const Node, lo: K, left: *usize, ctx: anytype) void {
            var i = x.lower(lo);
            while (i <= x.n) : (i += 1) {
                if (!x.leaf) {
                    scan(x.kids[i], lo, left, ctx);
                    if (left.* == 0) return;
                }
                if (i == x.n) return;
                ctx.visit(x.keys[i], x.vals[i]);
                left.* -= 1;
                if (left.* == 0) return;
            }
        }
    };
}

const Checksum = struct {
    sum: u64 = 0,

    fn visit(self: *Checksum, k: u64, v: u64) void {
        self.sum = self.sum *% 31 +% k +% v;
    }
};

var seed: u64 = 88172645463325252;

fn next() u64 {
    seed ^= seed << 13;
    seed ^= seed >> 7;
    seed ^= seed << 17;
    return seed;
}

pub fn main(init: std.process.Init) !void {
    var args = init.minimal.args.iterate();
    _ = args.skip();
    const n: usize = if (args.next()) |s| try std.fmt.parseInt(usize, s, 10) else 2000000;
    const gpa = init.gpa;
    const space = 2 * n; // keys are drawn from 0..space
    const Map = BTree(u64, u64);
    var t = try Map.init(gpa);
    defer t.deinit(gpa);
    for (0..n) |i| try t.put(gpa, next() % space, i);
    var hits: usize = 0;
    var check: Checksum = .{};
    for (0..n) |_| {
        if (t.get(next() % space)) |v| {
            hits += 1;
            check.sum +%= v.*;
        }
    }
    for (0..n / 10) |_| {
        var left: usize = 100;
        Map.scan(t.root, next() % space, &left, &check);
    }
    var buf: [256]u8 = undefined;
    var fw = std.Io.File.stdout().writer(init.io, &buf);
    const w = &fw.interface;
    try w.print("{d} entries, {d} of {d} lookups found\n", .{ t.len, hits, n });
    try w.print("checksum {d}\n", .{check.sum});
    try w.flush();
}
