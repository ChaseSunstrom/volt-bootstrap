// json: generate a JSON array of n objects (nested arrays and objects, escaped strings, ints and
// decimals) as text, parse it into a tree, then walk the tree for counts and sums; Zig hand-writes a
// recursive-descent parser into a tagged union tree (allocated slices, ArrayLists, members in order),
// numbers by std.fmt.parseFloat, failures as errors, and walks with a switch
const std = @import("std");
const Allocator = std.mem.Allocator;

const Rng = struct {
    x: u64 = 88172645463325252,

    fn next(r: *Rng) u64 {
        r.x ^= r.x << 13;
        r.x ^= r.x >> 7;
        r.x ^= r.x << 17;
        return r.x;
    }
};

// ---------- the text ----------

const words = [_][]const u8{ "alpha", "bravo", "charlie", "delta", "echo", "foxtrot", "golf", "hotel" };
const escapes = [_][]const u8{ "\\\"", "\\\\", "\\n", "\\t", "\\u00e9" };

// a string of 2 to 5 pieces, a quarter of them escapes
fn putName(out: *std.ArrayList(u8), gpa: Allocator, rng: *Rng) !void {
    try out.append(gpa, '"');
    const pieces = 2 + rng.next() % 4;
    for (0..pieces) |_| {
        if (rng.next() % 4 == 0) {
            try out.appendSlice(gpa, escapes[rng.next() % 5]);
        } else {
            try out.appendSlice(gpa, words[rng.next() % 8]);
        }
    }
    try out.append(gpa, '"');
}

fn putObject(out: *std.ArrayList(u8), gpa: Allocator, rng: *Rng, i: i64) !void {
    try out.print(gpa, "{{\"id\":{d},\"name\":", .{i});
    try putName(out, gpa, rng);
    const cents = rng.next() % 1000000;
    try out.print(gpa, ",\"score\":{d}.{d:0>2},\"tags\":[", .{ cents / 100, cents % 100 });
    const tags = rng.next() % 5;
    for (0..tags) |k| {
        if (k > 0) try out.append(gpa, ',');
        try out.append(gpa, '"');
        try out.appendSlice(gpa, words[rng.next() % 8]);
        try out.append(gpa, '"');
    }
    try out.appendSlice(gpa, "],\"pos\":[");
    for (0..3) |k| {
        if (k > 0) try out.append(gpa, ',');
        try out.print(gpa, "{d}", .{@as(i64, @intCast(rng.next() % 2000001)) - 1000000});
    }
    try out.appendSlice(gpa, if (rng.next() % 2 != 0) "],\"active\":true" else "],\"active\":false");
    try out.print(gpa, ",\"meta\":{{\"level\":{d}", .{rng.next() % 10});
    try out.print(gpa, ",\"ratio\":0.{d:0>3},\"note\":", .{rng.next() % 1000});
    if (rng.next() % 3 == 0) {
        try out.appendSlice(gpa, "null");
    } else {
        try putName(out, gpa, rng);
    }
    try out.appendSlice(gpa, "}}");
}

// ---------- the tree ----------

const Value = union(enum) {
    null,
    bool: bool,
    num: f64,
    str: []u8,
    arr: std.ArrayList(Value),
    obj: std.ArrayList(Member),

    fn deinit(v: *Value, gpa: Allocator) void {
        switch (v.*) {
            .str => |s| gpa.free(s),
            .arr => |*a| {
                for (a.items) |*item| item.deinit(gpa);
                a.deinit(gpa);
            },
            .obj => |*o| {
                for (o.items) |*m| {
                    gpa.free(m.name);
                    m.item.deinit(gpa);
                }
                o.deinit(gpa);
            },
            else => {},
        }
    }

    // an object's member called key, or null
    fn get(v: *const Value, key: []const u8) ?*const Value {
        switch (v.*) {
            .obj => |o| for (o.items) |*m| {
                if (std.mem.eql(u8, m.name, key)) return &m.item;
            },
            else => {},
        }
        return null;
    }
};

const Member = struct {
    name: []u8,
    item: Value,
};

// ---------- parsing: error.NotJson for text that isn't JSON ----------

const Error = error{ NotJson, OutOfMemory };

fn hex4(s: *const [4]u8) error{NotJson}!u16 {
    var v: u16 = 0;
    for (s) |c| v = v << 4 | (std.fmt.charToDigit(c, 16) catch return error.NotJson);
    return v;
}

const Parser = struct {
    s: []const u8,
    p: usize = 0,
    gpa: Allocator,

    fn skipSpace(ps: *Parser) void {
        while (ps.p < ps.s.len and (ps.s[ps.p] == ' ' or ps.s[ps.p] == '\t' or ps.s[ps.p] == '\n' or ps.s[ps.p] == '\r')) ps.p += 1;
    }

    fn at(ps: *const Parser, c: u8) bool {
        return ps.p < ps.s.len and ps.s[ps.p] == c;
    }

    // the string literal at p (its opening quote), unescaped into an allocated buffer: escapes only
    // shrink, so the raw length is enough
    fn string(ps: *Parser) Error![]u8 {
        const s = ps.s;
        var i = ps.p + 1;
        var e = i;
        while (e < s.len and s[e] != '"') e += if (s[e] == '\\') 2 else 1;
        if (e >= s.len) return error.NotJson;
        var o: std.ArrayList(u8) = try .initCapacity(ps.gpa, e - i);
        errdefer o.deinit(ps.gpa);
        while (i < e) {
            const c = s[i];
            if (c < 0x20) return error.NotJson;
            if (c != '\\') {
                o.appendAssumeCapacity(c);
                i += 1;
                continue;
            }
            const esc = s[i + 1];
            i += 2;
            switch (esc) {
                'n' => o.appendAssumeCapacity('\n'),
                't' => o.appendAssumeCapacity('\t'),
                'r' => o.appendAssumeCapacity('\r'),
                'b' => o.appendAssumeCapacity(8),
                'f' => o.appendAssumeCapacity(12),
                '"', '\\', '/' => o.appendAssumeCapacity(esc),
                'u' => {
                    if (e - i < 4) return error.NotJson;
                    var cp: u21 = try hex4(s[i..][0..4]);
                    i += 4;
                    // a surrogate pair is one code point
                    if (cp >= 0xD800 and cp < 0xDC00 and e - i >= 6 and s[i] == '\\' and s[i + 1] == 'u') {
                        const lo = hex4(s[i + 2 ..][0..4]) catch 0;
                        if (lo >= 0xDC00 and lo < 0xE000) {
                            cp = 0x10000 + ((cp - 0xD800) << 10) + (lo - 0xDC00);
                            i += 6;
                        }
                    }
                    var b: [4]u8 = undefined;
                    const len = std.unicode.utf8Encode(cp, &b) catch return error.NotJson;
                    o.appendSliceAssumeCapacity(b[0..len]);
                },
                else => return error.NotJson,
            }
        }
        ps.p = e + 1;
        return o.toOwnedSlice(ps.gpa);
    }

    fn word(ps: *Parser, w: []const u8) bool {
        if (!std.mem.startsWith(u8, ps.s[ps.p..], w)) return false;
        ps.p += w.len;
        return true;
    }

    fn value(ps: *Parser, depth: u32) Error!Value {
        const gpa = ps.gpa;
        if (depth > 512) return error.NotJson;
        ps.skipSpace();
        if (ps.p >= ps.s.len) return error.NotJson;
        switch (ps.s[ps.p]) {
            '[' => {
                ps.p += 1;
                var v: Value = .{ .arr = .empty };
                errdefer v.deinit(gpa);
                ps.skipSpace();
                if (ps.at(']')) {
                    ps.p += 1;
                    return v;
                }
                while (true) {
                    try v.arr.ensureUnusedCapacity(gpa, 1);
                    v.arr.appendAssumeCapacity(try ps.value(depth + 1));
                    ps.skipSpace();
                    if (ps.at(',')) {
                        ps.p += 1;
                    } else if (ps.at(']')) {
                        ps.p += 1;
                        return v;
                    } else return error.NotJson;
                }
            },
            '{' => {
                ps.p += 1;
                var v: Value = .{ .obj = .empty };
                errdefer v.deinit(gpa);
                ps.skipSpace();
                if (ps.at('}')) {
                    ps.p += 1;
                    return v;
                }
                while (true) {
                    ps.skipSpace();
                    if (!ps.at('"')) return error.NotJson;
                    try v.obj.ensureUnusedCapacity(gpa, 1);
                    const name = try ps.string();
                    ps.skipSpace();
                    if (!ps.at(':')) {
                        gpa.free(name);
                        return error.NotJson;
                    }
                    ps.p += 1;
                    const item = ps.value(depth + 1) catch |err| {
                        gpa.free(name);
                        return err;
                    };
                    v.obj.appendAssumeCapacity(.{ .name = name, .item = item });
                    ps.skipSpace();
                    if (ps.at(',')) {
                        ps.p += 1;
                    } else if (ps.at('}')) {
                        ps.p += 1;
                        return v;
                    } else return error.NotJson;
                }
            },
            '"' => return .{ .str = try ps.string() },
            else => {
                if (ps.word("true")) return .{ .bool = true };
                if (ps.word("false")) return .{ .bool = false };
                if (ps.word("null")) return .null;
                var end = ps.p;
                while (end < ps.s.len) : (end += 1) switch (ps.s[end]) {
                    '0'...'9', '-', '+', '.', 'e', 'E' => {},
                    else => break,
                };
                const num = std.fmt.parseFloat(f64, ps.s[ps.p..end]) catch return error.NotJson;
                ps.p = end;
                return .{ .num = num };
            },
        }
    }
};

fn jsonParse(gpa: Allocator, text: []const u8) Error!Value {
    var ps: Parser = .{ .s = text, .gpa = gpa };
    var v = try ps.value(0);
    errdefer v.deinit(gpa);
    ps.skipSpace();
    if (ps.p != text.len) return error.NotJson;
    return v;
}

// ---------- walking ----------

const Stats = struct { objects: i64 = 0, arrays: i64 = 0, strings: i64 = 0, numbers: i64 = 0, trues: i64 = 0, nulls: i64 = 0, string_bytes: usize = 0 };

fn walk(v: *const Value, s: *Stats) void {
    switch (v.*) {
        .null => s.nulls += 1,
        .bool => |b| s.trues += @intFromBool(b),
        .num => s.numbers += 1,
        .str => |t| {
            s.strings += 1;
            s.string_bytes += t.len;
        },
        .arr => |a| {
            s.arrays += 1;
            for (a.items) |*item| walk(item, s);
        },
        .obj => |o| {
            s.objects += 1;
            for (o.items) |*m| walk(&m.item, s);
        },
    }
}

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    var args = init.minimal.args.iterate();
    _ = args.skip();
    const n = if (args.next()) |a| try std.fmt.parseInt(i64, a, 10) else 400000;
    var rng: Rng = .{};
    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(gpa);
    try text.append(gpa, '[');
    var i: i64 = 0;
    while (i < n) : (i += 1) {
        if (i > 0) try text.appendSlice(gpa, ",\n");
        try putObject(&text, gpa, &rng, i);
    }
    try text.appendSlice(gpa, "]\n");
    var doc = jsonParse(gpa, text.items) catch |err| switch (err) {
        error.NotJson => {
            std.debug.print("not JSON\n", .{});
            std.process.exit(1);
        },
        else => |e| return e,
    };
    defer doc.deinit(gpa);
    var s: Stats = .{};
    walk(&doc, &s);
    var ids: i64 = 0;
    var cents: i64 = 0;
    for (doc.arr.items) |*item| {
        if (item.get("id")) |id| if (id.* == .num) {
            ids += @intFromFloat(id.num);
        };
        if (item.get("score")) |score| if (score.* == .num) {
            cents += @intFromFloat(score.num * 100.0 + 0.5);
        };
    }
    var buf: [4096]u8 = undefined;
    var w = std.Io.File.stdout().writer(init.io, &buf);
    const out = &w.interface;
    try out.print("{d} bytes: {d} objects, {d} arrays, {d} strings, {d} numbers\n", .{ text.items.len, s.objects, s.arrays, s.strings, s.numbers });
    try out.print("{d} string bytes, {d} true, {d} null\n", .{ s.string_bytes, s.trues, s.nulls });
    try out.print("{d} {d}\n", .{ ids, cents });
    try out.flush();
}
