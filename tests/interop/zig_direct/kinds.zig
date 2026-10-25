// Zig's other kinds of types, called from Volt: a packed struct, a tagged union, a bare union, an
// opaque type and extern fns (one provided by impl.zig's export fn)
const std = @import("std");

pub const Flags = packed struct {
    a: bool,
    b: u3,
    c: i7,
};

pub fn flagsSum(f: Flags) i32 {
    return @as(i32, f.b) + @as(i32, f.c) + @as(i32, @intFromBool(f.a));
}

pub fn makeFlags(c: i8) Flags {
    return .{ .a = false, .b = 7, .c = @intCast(c) };
}

pub const Rect = struct { w: f32, h: f32 };

pub const Shape = union(enum) {
    circle: f32,
    rect: Rect,
    none,

    pub fn isRound(self: Shape) bool {
        return self == .circle;
    }

    pub fn grow(self: *Shape, k: f32) void {
        switch (self.*) {
            .circle => |*r| r.* *= k,
            .rect => |*r| {
                r.w *= k;
                r.h *= k;
            },
            .none => {},
        }
    }
};

pub fn shapeArea(s: Shape) f32 {
    return switch (s) {
        .circle => |r| 3.0 * r * r,
        .rect => |r| r.w * r.h,
        .none => 0,
    };
}

// a payload that frees what it holds: the union's drop frees it (the leak check sees it)
pub const Buf = struct {
    data: []u8,

    pub fn init(allocator: std.mem.Allocator, n: usize) Buf {
        return .{ .data = allocator.alloc(u8, n) catch @panic("out of memory") };
    }

    pub fn deinit(self: *Buf, allocator: std.mem.Allocator) void {
        allocator.free(self.data);
    }
};

pub const Held = union(enum) {
    buf: Buf,
    empty,
};

pub fn heldLen(h: *const Held) usize {
    return switch (h.*) {
        .buf => |b| b.data.len,
        .empty => 0,
    };
}

pub fn bufLen(b: *const Buf) usize {
    return b.data.len;
}

// payloads Volt's makers copy: the union frees the copy when it's dropped (one Zig made, never)
pub const Note = union(enum) {
    text: []const u8,
    nums: []const i32,
    maybe: ?[]const u8,
    at: *const Rect,
    none,
};

pub fn noteSize(n: *const Note) f32 {
    return switch (n.*) {
        .text => |t| @floatFromInt(t.len),
        .nums => |xs| blk: {
            var t: i32 = 0;
            for (xs) |x| t += x;
            break :blk @floatFromInt(t);
        },
        .maybe => |m| if (m) |t| @floatFromInt(t.len) else -1,
        .at => |r| r.w * r.h,
        .none => 0,
    };
}

pub fn noteOf(text: bool) Note {
    return if (text) .{ .text = "zig's" } else .none;
}

// a copy of a union Volt made, handed back: Volt's own union stays the one that frees the copy
pub fn noteSame(n: Note) Note {
    return n;
}

// a bare union whose payloads Volt copies or moves in: Volt remembers the field it set, and the drop
// (or the next set) frees that one's payload
pub const Slot = union {
    text: []const u8,
    nums: []const i32,
    buf: Buf,
    n: i32,
};

pub fn slotLen(s: *const Slot, which: u8) usize {
    return switch (which) {
        0 => s.text.len,
        1 => s.nums.len,
        2 => s.buf.data.len,
        else => @intCast(s.n),
    };
}

// an optional payload that frees what it holds: freed too when it's there
pub const Kept = union(enum) {
    buf: ?Buf,
    empty,
};

pub fn keptOf(allocator: std.mem.Allocator, n: usize) Kept {
    return .{ .buf = if (n == 0) null else Buf.init(allocator, n) };
}

pub fn keptLen(k: *const Kept) usize {
    return switch (k.*) {
        .buf => |b| if (b) |x| x.data.len else 0,
        .empty => 0,
    };
}

pub const Bits = union {
    i: u32,
    f: f32,
};

pub fn bitsOf(x: f32) Bits {
    return .{ .f = x };
}

pub const Ctx = opaque {};

const CtxImpl = struct { total: i32 };

pub fn ctxCreate(start: i32) *Ctx {
    const p = std.heap.page_allocator.create(CtxImpl) catch @panic("out of memory");
    p.* = .{ .total = start };
    return @ptrCast(p);
}

pub fn ctxMaybe(make: bool) ?*Ctx {
    return if (make) ctxCreate(100) else null;
}

pub fn ctxAdd(c: *Ctx, n: i32) void {
    const p: *CtxImpl = @ptrCast(@alignCast(c));
    p.total += n;
}

pub fn ctxTotal(c: *const Ctx) i32 {
    const p: *const CtxImpl = @ptrCast(@alignCast(c));
    return p.total;
}

pub fn ctxDestroy(c: *Ctx) void {
    const p: *CtxImpl = @ptrCast(@alignCast(c));
    std.heap.page_allocator.destroy(p);
}

pub fn ctxList(cs: []*Ctx) usize {
    return cs.len;
}

// a C symbol from elsewhere (impl.zig exports it)
pub extern "c" fn zig_ext_add(a: i32, b: i32) i32;
// (with a pointer to an opaque type: called through the shim)
pub extern "c" fn zig_ext_total(c: *const Ctx) i32;
// a platform's calling convention (Windows x64's on x86_64, C's elsewhere): through the shim
pub const win_cc: std.builtin.CallingConvention = if (@import("builtin").cpu.arch == .x86_64) .{ .x86_64_win = .{} } else .c;
pub extern fn zig_ext_win(a: i32) callconv(win_cc) i32;
// left out: a slice isn't C's (Zig refuses it in a C fn), Zig's own convention can't be exported
// for it to link, and a naked fn can't be called
pub extern "c" fn zig_ext_len(s: []const u8) usize;
pub extern fn zig_ext_auto(a: i32) callconv(.auto) i32;
pub extern fn zig_ext_naked() callconv(.naked) void;

// a pointer to a number, a fixed array, and slices of the file's struct (copies of Volt's mirrors,
// a mutable one written back)
pub fn bumpBy(p: *i32, by: i32) void {
    p.* += by;
}

pub fn peek(p: *const i32) i32 {
    return p.*;
}

pub fn sumThree(xs: [3]f32) f32 {
    return xs[0] + xs[1] + xs[2];
}

pub fn firstThree(n: i32) [3]i32 {
    return .{ n, n + 1, n + 2 };
}

pub fn totalArea(rs: []const Rect) f32 {
    var t: f32 = 0;
    for (rs) |r| t += r.w * r.h;
    return t;
}

pub fn growAll(rs: []Rect) void {
    for (rs) |*r| r.w += 1;
}

pub fn rects(allocator: std.mem.Allocator, n: usize) []Rect {
    const out = allocator.alloc(Rect, n) catch @panic("out of memory");
    for (out, 0..) |*r, i| r.* = .{ .w = @floatFromInt(i), .h = 2 };
    return out;
}

// a C string, a many-item pointer, a vector and a tuple struct
pub fn greet(name: [*:0]const u8) usize {
    return std.mem.len(name);
}

pub fn motto() [*:0]const u8 {
    return "zig!";
}

pub fn maybeName(on: bool) ?[*:0]const u8 {
    return if (on) "on" else null;
}

pub fn sumMany(p: [*]const i32, n: usize) i32 {
    var t: i32 = 0;
    for (p[0..n]) |x| t += x;
    return t;
}

pub fn fillMany(p: [*]i32, n: usize, v: i32) void {
    for (p[0..n]) |*x| x.* = v;
}

pub fn dot(a: @Vector(3, f32), b: @Vector(3, f32)) f32 {
    return @reduce(.Add, a * b);
}

pub fn halves(v: @Vector(2, f32)) @Vector(2, f32) {
    return v / @as(@Vector(2, f32), @splat(2));
}

pub fn divmod(a: i32, b: i32) struct { i32, i32 } {
    return .{ @divTrunc(a, b), @rem(a, b) };
}

pub fn swap(t: struct { i32, f64 }) struct { f64, i32 } {
    return .{ t[1], t[0] };
}

pub fn nameLen(n: ?[*:0]const u8) usize {
    return if (n) |x| std.mem.len(x) else 0;
}

pub fn shout(allocator: std.mem.Allocator, s: [*:0]const u8) [*:0]u8 {
    const t = std.mem.span(s);
    const out = allocator.allocSentinel(u8, t.len + 1, 0) catch @panic("out of memory");
    for (t, 0..) |c, i| out[i] = std.ascii.toUpper(c);
    out[t.len] = '!';
    return out;
}

// std.ArrayList and the hash maps: copies of Volt's vec and map (a *ArrayList's changes come back)
pub fn evensUpTo(allocator: std.mem.Allocator, n: i32) std.ArrayList(i32) {
    var l: std.ArrayList(i32) = .empty;
    var i: i32 = 0;
    while (i <= n) : (i += 2) l.append(allocator, i) catch @panic("out of memory");
    return l;
}

pub fn pushSquares(allocator: std.mem.Allocator, l: *std.ArrayList(i32), n: i32) void {
    var i: i32 = 1;
    while (i <= n) : (i += 1) l.append(allocator, i * i) catch @panic("out of memory");
}

pub fn listSum(l: *const std.ArrayList(i32)) i32 {
    var t: i32 = 0;
    for (l.items) |x| t += x;
    return t;
}

pub fn squaresMap(allocator: std.mem.Allocator, n: u32) std.AutoHashMap(u32, u64) {
    var m = std.AutoHashMap(u32, u64).init(allocator);
    var i: u32 = 1;
    while (i <= n) : (i += 1) m.put(i, @as(u64, i) * i) catch @panic("out of memory");
    return m;
}

pub fn mapTotal(m: *const std.AutoHashMap(u32, u64)) u64 {
    var t: u64 = 0;
    var it = m.iterator();
    while (it.next()) |e| t += e.value_ptr.*;
    return t;
}

pub fn wordLens(allocator: std.mem.Allocator, text: []const u8) std.StringHashMap(usize) {
    var m = std.StringHashMap(usize).init(allocator);
    var it = std.mem.tokenizeScalar(u8, text, ' ');
    while (it.next()) |w| m.put(w, w.len) catch @panic("out of memory");
    return m;
}

pub fn lenOf(m: *const std.StringHashMap(usize), w: []const u8) usize {
    return m.get(w) orelse 0;
}
