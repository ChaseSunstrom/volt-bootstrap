// huffman: Huffman-code a skewed 64-letter text: count the letters, build the code tree from a
// priority queue of (weight, node), write every letter's code as bits, then read the bits back a bit
// at a time down the tree and check the round trip; Zig uses std.PriorityQueue and optional children
const std = @import("std");

const Node = struct {
    children: ?[2]usize, // null on a leaf
    sym: u8,
};

const Item = struct { weight: u64, id: usize };

fn order(_: void, a: Item, b: Item) std.math.Order {
    return std.math.order(a.weight, b.weight).differ() orelse std.math.order(a.id, b.id);
}

fn assign(nodes: []const Node, id: usize, code: u64, len: u6, codes: *[256]u64, lens: *[256]u6) void {
    if (nodes[id].children) |ch| {
        assign(nodes, ch[0], code << 1, len + 1, codes, lens);
        assign(nodes, ch[1], (code << 1) | 1, len + 1, codes, lens);
    } else {
        codes[nodes[id].sym] = code;
        lens[nodes[id].sym] = len;
    }
}

fn fnv(s: []const u8) u64 {
    var h: u64 = 14695981039346656037;
    for (s) |c| h = (h ^ c) *% 1099511628211;
    return h;
}

var x: u64 = 88172645463325252;

fn next() u64 {
    x ^= x << 13;
    x ^= x >> 7;
    x ^= x << 17;
    return x;
}

pub fn main(init: std.process.Init) !void {
    var args = init.minimal.args.iterate();
    _ = args.skip();
    const n: usize = if (args.next()) |s| try std.fmt.parseInt(usize, s, 10) else 33554432;
    const gpa = init.gpa;
    // the text: letters of a 64-letter alphabet, the first ones the most common
    const alphabet = "etaoinshrdlcumwfgypbvkjxqzETAOINSHRDLCUMWFGYPBVKJXQZ0123456789 .";
    const text = try gpa.alloc(u8, n);
    defer gpa.free(text);
    for (text) |*c| {
        const r = next();
        c.* = alphabet[((r >> 8) % 64) * ((r >> 20) % 64) / 63];
    }
    var count: [256]u64 = @splat(0);
    for (text) |c| count[c] += 1;
    // a leaf per letter that occurs, in byte order; then a node joining the two lightest, until one is left
    var nodes: std.ArrayList(Node) = .empty;
    defer nodes.deinit(gpa);
    var queue: std.PriorityQueue(Item, void, order) = .empty;
    defer queue.deinit(gpa);
    for (count, 0..) |w, c| {
        if (w > 0) {
            try queue.push(gpa, .{ .weight = w, .id = nodes.items.len });
            try nodes.append(gpa, .{ .children = null, .sym = @intCast(c) });
        }
    }
    const symbols = nodes.items.len;
    while (queue.count() > 1) {
        const a = queue.pop().?;
        const b = queue.pop().?;
        try queue.push(gpa, .{ .weight = a.weight + b.weight, .id = nodes.items.len });
        try nodes.append(gpa, .{ .children = .{ a.id, b.id }, .sym = 0 });
    }
    const root = queue.pop().?.id;
    var codes: [256]u64 = @splat(0);
    var lens: [256]u6 = @splat(0);
    assign(nodes.items, root, 0, 0, &codes, &lens);
    const longest: usize = std.mem.max(u6, &lens);
    // write the codes, the first bit of each byte the highest
    var bytes: std.ArrayList(u8) = try .initCapacity(gpa, n * longest / 8 + 1);
    defer bytes.deinit(gpa);
    var acc: u64 = 0;
    var bits: u6 = 0;
    for (text) |c| {
        acc = (acc << lens[c]) | codes[c];
        bits += lens[c];
        while (bits >= 8) {
            bits -= 8;
            bytes.appendAssumeCapacity(@truncate(acc >> bits));
        }
    }
    if (bits > 0) bytes.appendAssumeCapacity(@truncate(acc << (8 - bits)));
    // read them back down the tree
    const back = try gpa.alloc(u8, n);
    defer gpa.free(back);
    var pos: usize = 0;
    for (back) |*c| {
        var id = root;
        while (nodes.items[id].children) |ch| {
            const bit = (bytes.items[pos >> 3] >> @intCast(7 - (pos & 7))) & 1;
            pos += 1;
            id = ch[bit];
        }
        c.* = nodes.items[id].sym;
    }
    if (!std.mem.eql(u8, back, text)) {
        std.debug.print("round trip failed\n", .{});
        std.process.exit(1);
    }
    var buf: [512]u8 = undefined;
    var fw = std.Io.File.stdout().writer(init.io, &buf);
    const w = &fw.interface;
    try w.print("{d} letters, {d} symbols, longest code {d} bits\n", .{ n, symbols, longest });
    try w.print("packed {d} bytes, checksum {d}\n", .{ bytes.items.len, fnv(bytes.items) });
    try w.print("unpacked {d} bytes, checksum {d}\n", .{ n, fnv(back) });
    try w.flush();
}
