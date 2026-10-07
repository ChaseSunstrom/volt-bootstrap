// bigint: arbitrary-precision integers in base 1e9 limbs: n! by repeated small multiplies, the m-th Fibonacci number by repeated additions, and a schoolbook product of two big numbers
const std = @import("std");
const Allocator = std.mem.Allocator;

const base: u32 = 1_000_000_000;

/// limbs, least significant first
const Big = struct {
    limbs: std.ArrayList(u32),

    fn from(gpa: Allocator, v: u32) !Big {
        var limbs: std.ArrayList(u32) = .empty;
        try limbs.append(gpa, v);
        return .{ .limbs = limbs };
    }

    fn deinit(b: *Big, gpa: Allocator) void {
        b.limbs.deinit(gpa);
    }

    fn mulSmall(b: *Big, gpa: Allocator, k: u32) !void {
        var carry: u64 = 0;
        for (b.limbs.items) |*l| {
            const x = @as(u64, l.*) * k + carry;
            l.* = @intCast(x % base);
            carry = x / base;
        }
        while (carry != 0) {
            try b.limbs.append(gpa, @intCast(carry % base));
            carry /= base;
        }
    }

    fn add(gpa: Allocator, a: *const Big, b: *const Big) !Big {
        const l, const s = if (a.limbs.items.len >= b.limbs.items.len) .{ a.limbs.items, b.limbs.items } else .{ b.limbs.items, a.limbs.items };
        var r: std.ArrayList(u32) = try .initCapacity(gpa, l.len + 1);
        var carry: u32 = 0;
        for (l, 0..) |li, i| {
            const x = li + (if (i < s.len) s[i] else 0) + carry;
            carry = @intFromBool(x >= base);
            r.appendAssumeCapacity(if (carry != 0) x - base else x);
        }
        if (carry != 0) r.appendAssumeCapacity(1);
        return .{ .limbs = r };
    }

    fn mul(gpa: Allocator, a: *const Big, b: *const Big) !Big {
        const al = a.limbs.items;
        const bl = b.limbs.items;
        var r: std.ArrayList(u32) = try .initCapacity(gpa, al.len + bl.len);
        r.appendNTimesAssumeCapacity(0, al.len + bl.len);
        const rl = r.items;
        for (al, 0..) |ai, i| {
            var carry: u64 = 0;
            for (bl, 0..) |bj, j| {
                const x = rl[i + j] + @as(u64, ai) * bj + carry;
                rl[i + j] = @intCast(x % base);
                carry = x / base;
            }
            rl[i + bl.len] = @intCast(carry);
        }
        while (r.items.len > 1 and r.items[r.items.len - 1] == 0) r.items.len -= 1;
        return .{ .limbs = r };
    }

    /// digit count and digit sum
    fn report(b: *const Big, out: *std.Io.Writer, what: []const u8) !void {
        var sum: u64 = 0;
        for (b.limbs.items) |l| {
            var x = l;
            while (x != 0) : (x /= 10) sum += x % 10;
        }
        var digits = (b.limbs.items.len - 1) * 9;
        var top = b.limbs.items[b.limbs.items.len - 1];
        while (top != 0) : (top /= 10) digits += 1;
        try out.print("{s}: {d} digits, digit sum {d}\n", .{ what, digits, sum });
    }
};

pub fn main(init: std.process.Init) !void {
    var args = init.minimal.args.iterate();
    _ = args.skip();
    const n: u32 = if (args.next()) |a| try std.fmt.parseInt(u32, a, 10) else 20000;
    const gpa = init.gpa;
    var buf: [256]u8 = undefined;
    var w = std.Io.File.stdout().writer(init.io, &buf);
    const out = &w.interface;

    var f = try Big.from(gpa, 1);
    defer f.deinit(gpa);
    for (2..n + 1) |k| try f.mulSmall(gpa, @intCast(k));
    try f.report(out, "factorial");
    // fib[i % 2] steps through the Fibonacci numbers, each sum replacing the older of the two
    var fib = [2]Big{ try .from(gpa, 0), try .from(gpa, 1) };
    defer for (&fib) |*b| b.deinit(gpa);
    for (0..n * 10) |i| {
        const sum = try Big.add(gpa, &fib[0], &fib[1]);
        fib[i % 2].deinit(gpa);
        fib[i % 2] = sum;
    }
    try fib[1].report(out, "fibonacci");
    var p = try Big.mul(gpa, &f, &fib[1]);
    defer p.deinit(gpa);
    try p.report(out, "product");
    try out.flush();
}
