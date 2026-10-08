//! An ordinary Zig file: nothing in it is written for Volt. main.volt next to it calls it with
//! `use zig { "fastmath.zig" } as fm;`.
const std = @import("std");

pub const shapes = @import("shapes.zig");

pub const LIMIT = 10;
pub const NAME = "fastmath";
pub const RATIO: f64 = 1.5;

pub const Point = struct {
    x: f64,
    y: f64 = 0,

    pub fn init(x: f64, y: f64) Point {
        return .{ .x = x, .y = y };
    }

    pub fn norm(self: Point) f64 {
        return @sqrt(self.x * self.x + self.y * self.y);
    }

    pub fn scale(self: *Point, k: f64) void {
        self.x *= k;
        self.y *= k;
    }
};

pub const Color = enum(u8) {
    red,
    green = 5,
    blue,

    pub fn name(self: Color) []const u8 {
        return @tagName(self);
    }
};

pub const Pixel = struct {
    at: Point,
    color: Color,
};

pub fn add(a: i32, b: i32) i32 {
    return a + b;
}

pub fn dist(a: Point, b: Point) f64 {
    const dx = a.x - b.x;
    const dy = a.y - b.y;
    return @sqrt(dx * dx + dy * dy);
}

pub fn sum(xs: []const f64) f64 {
    var t: f64 = 0;
    for (xs) |x| t += x;
    return t;
}

pub fn doubleAll(xs: []i32) void {
    for (xs) |*x| x.* *= 2;
}

pub fn firstWord(s: []const u8) []const u8 {
    var it = std.mem.tokenizeScalar(u8, s, ' ');
    return it.next() orelse "";
}

pub fn upper(allocator: std.mem.Allocator, s: []const u8) ![]u8 {
    const out = try allocator.alloc(u8, s.len);
    for (s, 0..) |c, i| out[i] = std.ascii.toUpper(c);
    return out;
}

pub fn squares(allocator: std.mem.Allocator, n: usize) ![]u64 {
    const out = try allocator.alloc(u64, n);
    for (out, 1..) |*x, i| x.* = i * i;
    return out;
}

pub fn join(allocator: std.mem.Allocator, parts: []const []const u8, sep: []const u8) ![]u8 {
    return std.mem.join(allocator, sep, parts);
}

pub fn find(xs: []const i32, x: i32) ?usize {
    for (xs, 0..) |y, i| {
        if (y == x) return i;
    }
    return null;
}

pub fn orDefault(x: ?i64) i64 {
    return x orelse -1;
}

pub fn parseNum(s: []const u8) !i64 {
    return std.fmt.parseInt(i64, std.mem.trim(u8, s, " "), 10);
}

pub fn checkedDiv(a: i32, b: i32) error{DivisionByZero}!i32 {
    if (b == 0) return error.DivisionByZero;
    return @divTrunc(a, b);
}

pub fn nextColor(c: Color) Color {
    return switch (c) {
        .red => .green,
        .green => .blue,
        .blue => .red,
    };
}

pub fn brighten(p: *Pixel) void {
    p.color = nextColor(p.color);
    p.at.scale(2);
}

pub const util = struct {
    pub fn twice(x: i32) i32 {
        return x * 2;
    }
};

// not callable from Volt: a packed struct, a declaration without a body
pub const Flags = packed struct {
    a: bool = false,
    b: bool = false,
};

pub extern fn defined_elsewhere(x: i32) i32;

// generics: zig builds an instance per one a program uses
pub fn largest(comptime T: type, xs: []const T) T {
    return std.mem.max(T, xs);
}

pub fn biggerOf(a: anytype, b: @TypeOf(a)) @TypeOf(a) {
    return if (a > b) a else b;
}

pub fn times(comptime n: usize, x: i32) i32 {
    return x * @as(i32, @intCast(n));
}

pub fn scaled(comptime k: comptime_int, x: i64) i64 {
    return x * k;
}

// what it allocates is never freed: it's Volt's memory, so Volt's leak check sees it
pub fn leakBytes(allocator: std.mem.Allocator, n: usize) void {
    _ = allocator.alloc(u8, n) catch return;
}

pub fn Pair(comptime T: type) type {
    return struct {
        a: T,
        b: T,

        pub fn sum(self: @This()) T {
            return self.a + self.b;
        }
    };
}

pub fn Stack(comptime T: type) type {
    return struct {
        const Self = @This();
        items: []T,
        n: usize,

        pub fn init(allocator: std.mem.Allocator, cap: usize) !Self {
            return .{ .items = try allocator.alloc(T, cap), .n = 0 };
        }

        pub fn push(self: *Self, x: T) bool {
            if (self.n == self.items.len) return false;
            self.items[self.n] = x;
            self.n += 1;
            return true;
        }

        // a number's (zig rejects it for a Stack(bool): that instance has the rest)
        pub fn total(self: *const Self) T {
            var t: T = 0;
            for (self.items[0..self.n]) |x| t += x;
            return t;
        }

        pub fn pop(self: *Self) ?T {
            if (self.n == 0) return null;
            self.n -= 1;
            return self.items[self.n];
        }

        pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
            allocator.free(self.items);
        }
    };
}
