// errors: lines of comma-separated numbers, about 1 in 100 malformed, parsed through three layers of calls; Zig returns an error union and passes errors up with try
const std = @import("std");

const ParseError = error{ Empty, BadDigit };

const Parser = struct {
    text: []const u8,
    pos: usize = 0,

    fn peek(p: *const Parser) ?u8 {
        return if (p.pos < p.text.len) p.text[p.pos] else null;
    }

    /// the digits up to the next ',' or '\n'; pos is kept in a local, since a byte read through p could alias p.pos
    fn parseDigits(p: *Parser) ParseError!i64 {
        const start = p.pos;
        var pos = p.pos;
        defer p.pos = pos;
        var v: i64 = 0;
        while (pos < p.text.len) : (pos += 1) {
            const c = p.text[pos];
            if (c == ',' or c == '\n') break;
            if (!std.ascii.isDigit(c)) return error.BadDigit;
            v = v * 10 + (c - '0');
        }
        if (pos == start) return error.Empty;
        return v;
    }

    fn parseNumber(p: *Parser) ParseError!i64 {
        if (p.peek() == '-') {
            p.pos += 1;
            return -(try p.parseDigits());
        }
        return p.parseDigits();
    }

    /// one line's numbers: their sum
    fn parseList(p: *Parser) ParseError!i64 {
        var sum: i64 = 0;
        while (true) {
            sum += try p.parseNumber();
            const c = p.peek() orelse break;
            if (c == '\n') break;
            p.pos += 1;
        }
        p.pos += 1;
        return sum;
    }

    fn skipLine(p: *Parser) void {
        while (p.peek()) |c| : (p.pos += 1) if (c == '\n') break;
        p.pos += 1;
    }
};

var rng: u64 = 88172645463325252;

fn next() u64 {
    rng ^= rng << 13;
    rng ^= rng >> 7;
    rng ^= rng << 17;
    return rng;
}

pub fn main(init: std.process.Init) !void {
    var args = init.minimal.args.iterate();
    _ = args.skip();
    const rounds: i64 = if (args.next()) |a| try std.fmt.parseInt(i64, a, 10) else 1000;
    const lines = 20000;
    // at most 10 fields a line, each at most "-999999x,"
    const text = try init.gpa.alloc(u8, lines * 91);
    defer init.gpa.free(text);
    var len: usize = 0;
    for (0..lines) |_| {
        const count = 1 + next() % 10;
        for (0..count) |k| {
            if (k > 0) {
                text[len] = ',';
                len += 1;
            }
            const r = next() % 200;
            if (r == 0) continue; // an empty field
            if (r % 4 == 2) {
                text[len] = '-';
                len += 1;
            }
            len += (try std.fmt.bufPrint(text[len..], "{d}", .{next() % 1000000})).len;
            if (r == 1) {
                text[len] = 'x'; // a stray letter
                len += 1;
            }
        }
        text[len] = '\n';
        len += 1;
    }
    var total: i64 = 0;
    var failures: i64 = 0;
    for (0..@intCast(rounds)) |_| {
        var p: Parser = .{ .text = text[0..len] };
        while (p.pos < len) {
            if (p.parseList()) |sum| {
                total += sum;
            } else |_| {
                failures += 1;
                p.skipLine();
            }
        }
    }
    var buf: [256]u8 = undefined;
    var w = std.Io.File.stdout().writer(init.io, &buf);
    try w.interface.print("{d} bytes, {d} total, {d} failures\n", .{ len, total, failures });
    try w.interface.flush();
}
