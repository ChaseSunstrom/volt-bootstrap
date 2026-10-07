// lexer: generate a large source text in a C-like toy language, tokenize it ten times, and count the
// tokens by kind (plus a checksum of the identifiers' lengths); Zig scans a byte slice by index in a
// Lexer whose next() returns an optional token, an enum kind plus a slice of its text
const std = @import("std");

const Kind = enum { ident, keyword, int, float, string, op, punct, comment, @"error" };

const keywords = [_][]const u8{ "fn", "let", "if", "else", "while", "for", "return", "struct", "true", "false" };

const Token = struct {
    kind: Kind,
    text: []const u8,
};

fn isAlpha(c: u8) bool {
    return std.ascii.isAlphabetic(c) or c == '_';
}

fn isKeyword(s: []const u8) bool {
    for (keywords) |k| if (std.mem.eql(u8, k, s)) return true;
    return false;
}

const Lexer = struct {
    src: []const u8,
    p: usize = 0,

    fn digitAt(lx: *const Lexer, i: usize) bool {
        return i < lx.src.len and std.ascii.isDigit(lx.src[i]);
    }

    fn next(lx: *Lexer) ?Token {
        const s = lx.src;
        const end = s.len;
        var p = lx.p;
        while (p < end and (s[p] == ' ' or s[p] == '\t' or s[p] == '\n' or s[p] == '\r')) p += 1;
        const start = p;
        if (p == end) return null;
        const c = s[p];
        p += 1;
        var k: Kind = undefined;
        if (isAlpha(c)) {
            while (p < end and (isAlpha(s[p]) or std.ascii.isDigit(s[p]))) p += 1;
            k = if (isKeyword(s[start..p])) .keyword else .ident;
        } else if (std.ascii.isDigit(c)) {
            k = .int;
            while (lx.digitAt(p)) p += 1;
            if (p + 1 < end and s[p] == '.' and std.ascii.isDigit(s[p + 1])) {
                k = .float;
                p += 1;
                while (lx.digitAt(p)) p += 1;
            }
            if (p < end and (s[p] == 'e' or s[p] == 'E')) {
                var q = p + 1;
                if (q < end and (s[q] == '+' or s[q] == '-')) q += 1;
                if (lx.digitAt(q)) {
                    k = .float;
                    p = q;
                    while (lx.digitAt(p)) p += 1;
                }
            }
        } else if (c == '"') {
            while (p < end and s[p] != '"') p += if (s[p] == '\\' and p + 1 < end) 2 else 1;
            if (p < end) p += 1;
            k = .string;
        } else if (c == '/' and p < end and s[p] == '/') {
            while (p < end and s[p] != '\n') p += 1;
            k = .comment;
        } else if (c == '/' and p < end and s[p] == '*') {
            p += 1;
            while (p + 1 < end and !(s[p] == '*' and s[p + 1] == '/')) p += 1;
            p = if (p + 1 < end) p + 2 else end;
            k = .comment;
        } else {
            k = switch (c) {
                '(', ')', '{', '}', '[', ']', ';', ',', '.' => .punct,
                // ==, !=, <=, >=, +=, *=, /=, %=
                '=', '!', '<', '>', '+', '*', '/', '%' => blk: {
                    if (p < end and s[p] == '=') p += 1;
                    break :blk .op;
                },
                '-' => blk: {
                    if (p < end and (s[p] == '=' or s[p] == '>')) p += 1;
                    break :blk .op;
                },
                // && and ||
                '&', '|' => blk: {
                    if (p < end and s[p] == c) p += 1;
                    break :blk .op;
                },
                else => .@"error",
            };
        }
        lx.p = p;
        return .{ .kind = k, .text = s[start..p] };
    }
};

// ---- the source text ----

const names = [_][]const u8{ "count", "index", "value", "node", "buf", "len", "total", "x", "y", "result", "item", "next_one", "left", "right", "data", "i" };
const words = [_][]const u8{ "the", "loop", "ends", "when", "it", "reaches", "zero", "todo" };
const pieces = [_][]const u8{ "hello", "world", "\\n", "\\t", "\\\"", "\\\\", " ", "value: " };
const ops = [_][]const u8{ "+", "-", "*", "/", "%" };
const cmps = [_][]const u8{ "==", "!=", "<", "<=", ">", ">=" };

const Gen = struct {
    out: std.ArrayList(u8) = .empty,
    gpa: std.mem.Allocator,
    x: u64 = 88172645463325252,

    fn next(g: *Gen) u64 {
        g.x ^= g.x << 13;
        g.x ^= g.x >> 7;
        g.x ^= g.x << 17;
        return g.x;
    }

    fn put(g: *Gen, s: []const u8) !void {
        try g.out.appendSlice(g.gpa, s);
    }

    fn putUint(g: *Gen, v: u64) !void {
        try g.out.print(g.gpa, "{d}", .{v});
    }

    fn ident(g: *Gen) !void {
        const r = g.next();
        try g.put(names[r % 16]);
        if ((r >> 8) % 4 == 0) {
            try g.put("_");
            try g.putUint((r >> 16) % 1000);
        }
    }

    fn int(g: *Gen) !void {
        try g.putUint(g.next() % 100000);
    }

    fn float(g: *Gen) !void {
        const r = g.next();
        try g.putUint(r % 1000);
        try g.put(".");
        try g.putUint((r >> 20) % 1000);
        if ((r >> 40) % 4 == 0) {
            try g.put("e");
            try g.putUint((r >> 50) % 20);
        }
    }

    fn string(g: *Gen) !void {
        const r = g.next();
        try g.put("\"");
        for (0..1 + r % 4) |k| try g.put(pieces[(r >> @intCast(8 + 3 * k)) % 8]);
        try g.put("\"");
    }

    fn prose(g: *Gen) !void {
        const r = g.next();
        for (0..2 + r % 6) |k| {
            try g.put(" ");
            try g.put(words[(r >> @intCast(8 + 3 * k)) % 8]);
        }
    }

    fn expr(g: *Gen) !void {
        const r = g.next();
        switch (r % 4) {
            0 => try g.ident(),
            1 => try g.int(),
            2 => try g.float(),
            else => {
                try g.ident();
                try g.put(" ");
                try g.put(ops[(r >> 8) % 5]);
                try g.put(" ");
                try g.int();
            },
        }
    }

    fn statement(g: *Gen) !void {
        const r = g.next();
        const cmp = cmps[(r >> 8) % 6];
        switch (r % 8) {
            0 => {
                try g.put("let ");
                try g.ident();
                try g.put(" = ");
                try g.expr();
                try g.put(";\n");
            },
            1 => {
                try g.put("if (");
                try g.expr();
                try g.put(" ");
                try g.put(cmp);
                try g.put(" ");
                try g.expr();
                try g.put(") {\n    ");
                try g.ident();
                try g.put(" = ");
                try g.expr();
                try g.put(";\n} else {\n    return ");
                try g.expr();
                try g.put(";\n}\n");
            },
            2 => {
                try g.put("while (");
                try g.ident();
                try g.put(" ");
                try g.put(cmp);
                try g.put(" ");
                try g.int();
                try g.put(" && ");
                try g.ident();
                try g.put(" != ");
                try g.int();
                try g.put(" || !");
                try g.ident();
                try g.put(") {\n    ");
                try g.ident();
                try g.put(" += ");
                try g.int();
                try g.put(";\n}\n");
            },
            3 => {
                try g.put("return ");
                try g.string();
                try g.put(";\n");
            },
            4 => {
                try g.put("//");
                try g.prose();
                try g.put("\n");
            },
            5 => {
                try g.put("/*");
                try g.prose();
                try g.put(" */\n");
            },
            6 => {
                try g.ident();
                try g.put("(");
                try g.expr();
                try g.put(", ");
                try g.expr();
                try g.put(");\n");
            },
            else => {
                try g.put("fn ");
                try g.ident();
                try g.put("(");
                try g.ident();
                try g.put(", ");
                try g.ident();
                try g.put(") -> ");
                try g.ident();
                try g.put(" {\n    let ");
                try g.ident();
                try g.put(" = ");
                try g.float();
                try g.put(" * ");
                try g.ident();
                try g.put(" - ");
                try g.int();
                try g.put(";\n}\n");
            },
        }
    }
};

pub fn main(init: std.process.Init) !void {
    var args = init.minimal.args.iterate();
    _ = args.skip();
    const n = if (args.next()) |a| try std.fmt.parseInt(usize, a, 10) else 32 << 20;
    var g: Gen = .{ .gpa = init.gpa };
    defer g.out.deinit(init.gpa);
    while (g.out.items.len < n) try g.statement();
    const src = g.out.items;
    var counts = std.enums.EnumArray(Kind, usize).initFill(0);
    var total: usize = 0;
    var check: u64 = 0;
    for (0..10) |_| {
        var lx: Lexer = .{ .src = src };
        while (lx.next()) |t| {
            counts.getPtr(t.kind).* += 1;
            total += 1;
            if (t.kind == .ident) check = check *% 31 +% t.text.len;
        }
    }
    var buf: [4096]u8 = undefined;
    var w = std.Io.File.stdout().writer(init.io, &buf);
    const out = &w.interface;
    try out.print("{d} bytes, {d} tokens\n", .{ src.len, total });
    var it = counts.iterator();
    while (it.next()) |e| try out.print("{t} {d}\n", .{ e.key, e.value.* });
    try out.print("identifier checksum {d}\n", .{check});
    try out.flush();
}
