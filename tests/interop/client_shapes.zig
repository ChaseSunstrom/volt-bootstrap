// Zig calls shapelib (voltc bindings --lang zig): a generic's instances, a struct held by a type with
// methods, owned values passed in, a Volt trait both ways (any type with its fns, lent or given; one
// Volt made, a volt_shape), closures taking and giving text, handles and errors, and closures given
// back
const std = @import("std");
const s = @import("shapelib.zig");
const print = std.debug.print;

const Circle = struct {
    r: f64,
    pub fn area(self: *Circle) f64 {
        return 3 * self.r * self.r;
    }
    pub fn name(self: *Circle) []const u8 {
        _ = self;
        return "circle";
    }
    pub fn grow(self: *Circle, by: f64) void {
        self.r += by;
    }
    pub fn deinit(self: *Circle) void {
        _ = self;
        print("circle gone\n", .{});
    }
};

fn deposit_one(_: void, b: s.account) i64 {
    return b.deposit(1);
}

fn bang(buf: *[32]u8, t: []const u8) []const u8 {
    return std.fmt.bufPrint(buf, "{s}!", .{t}) catch unreachable;
}

fn twice(_: void, x: i32) s.Error!i32 {
    return if (x > 5) error.OVERDRAWN else x * 2;
}

fn open_seven(_: void, owner: []const u8) s.account {
    const b = s.account.open(owner);
    _ = b.deposit(7);
    return b;
}

fn positive(_: void, x: i32) s.Error!void {
    if (x <= 0) return error.OVERDRAWN;
}

// what C and C++ don't print: an E!void callback, closures given back giving E!void and a str
fn extras() void {
    const ok = if (s.checked({}, positive, 1)) |_| true else |_| false;
    if (s.checked({}, positive, -1)) |_| {} else |e| print("checked {} {s}\n", .{ ok, @errorName(e) });
    var lim = s.limiter();
    defer lim.deinit();
    const under = if (lim.call(3)) |_| true else |_| false;
    if (lim.call(12)) |_| {} else |e| print("limit {} {s}\n", .{ under, @errorName(e) });
    var sign = s.labeler();
    defer sign.deinit();
    print("sign {s} {s}\n", .{ sign.call(5), sign.call(-1) });
}

// lists (VoltList out, slices in), slices of text and handles, optional text and handles
fn lists() void {
    const a = s.account.open("ann");
    _ = a.deposit(5);
    const b = s.account.open("bobby");
    _ = b.deposit(9);
    var ab = [_]s.account{ a, b };
    const os = s.owners(&ab);
    print("owners {d} {s} {s}\n", .{ os.items().len, os.items()[0].slice(), os.items()[1].slice() });
    os.deinit();
    print("richest {d}", .{s.richest(&ab)});
    print(" after {d} {d}\n", .{ a.get(), b.get() });
    const opened = s.open_all(&.{ "cy", "dee" });
    print("opened {d} {s}\n", .{ opened.items().len, opened.items()[1].owner() });
    for (opened.items()) |x| x.deinit();
    opened.deinit();
    const sq = s.squares_upto(4);
    print("squares {d} {d} sum {d}\n", .{ sq.items().len, sq.items()[3], s.sum_all(sq.items()) });
    sq.deinit();
    const parts = [_][]const u8{ "a", "b", "c" };
    const j = s.joined(&parts, "-");
    defer j.deinit();
    print("joined {s} total {d}\n", .{ j.bytes(), s.total_len(&parts) });
    const g1 = s.greeting("ann");
    defer g1.deinit();
    const g2 = s.greeting(null);
    defer g2.deinit();
    print("{s}; {s}\n", .{ g1.bytes(), g2.bytes() });
    const n1 = s.nickname(a);
    const n2 = s.nickname(b);
    print("nick {d} {s} {d}\n", .{ @intFromBool(n1 != null), n1.?.bytes(), @intFromBool(n2 != null) });
    if (n1) |t| t.deinit();
    const c = s.open_if("eve", true);
    const d = s.open_if("x", false);
    print("open_if {d} {d}\n", .{ @intFromBool(c != null), @intFromBool(d == null) });
    const c1 = s.close_if(c);
    print("close_if {d} {d}\n", .{ c1, s.close_if(null) });
    print("close_all {d}\n", .{s.close_all(&ab)});
    var some = [_]s.VoltOpt(i64){ .from(1), .from(null), .from(3) };
    print("some {d}\n", .{s.count_some(&some)});
    var r1 = [_]i64{ 1, 2 };
    var r2 = [_]i64{3};
    var rr = [_]s.VoltSlice(i64){ s.VoltSlice(i64).from(&r1), s.VoltSlice(i64).from(&r2) };
    print("rows {d}\n", .{s.total_rows(&rr)});
    print("lists closed {d}\n", .{s.closed_accounts()});
}

pub fn main() void {
    extras();
    var xs = [_]i32{ 3, 9, 4 };
    var ys = [_]f64{ 1.5, 0.5 };
    print("biggest {d} {d}\n", .{ s.biggest_i32(&xs), s.biggest_f64(&ys) });
    const a = s.account.open("ann");
    _ = a.deposit(250);
    a.rename("bea");
    var n = a.deposit(50);
    print("account {s} {d}\n", .{ a.owner(), n });
    n = s.visit(a, {}, deposit_one);
    print("visit {d} get {d}\n", .{ n, a.get() });
    n = s.close_account(a);
    print("closed {d} {d}\n", .{ n, s.closed_accounts() });
    var c = Circle{ .r = 1 };
    defer c.deinit();
    const d1 = s.describe(&c);
    defer d1.deinit();
    print("{s}\n", .{d1.bytes()});
    print("grown {d}\n", .{s.grow_twice(Circle{ .r = 1 })});
    var sq = s.make_square(2);
    defer sq.deinit();
    sq.grow(1);
    const nm = sq.name();
    defer nm.deinit();
    const area = sq.area();
    const d2 = s.describe(&sq);
    defer d2.deinit();
    print("{s} {d} {s}\n", .{ nm.bytes(), area, d2.bytes() });
    var buf: [32]u8 = undefined;
    const h = s.shout(&buf, bang, "hey");
    defer h.deinit();
    print("{s}\n", .{h.bytes()});
    print("try {d}", .{s.try_twice({}, twice, 1) catch unreachable});
    if (s.try_twice({}, twice, 4)) |_| {} else |e| print(" {s}\n", .{@errorName(e)});
    print("opened {d}\n", .{s.opened_by({}, open_seven)});
    print("closed {d}\n", .{s.closed_accounts()});
    var d = s.doubler();
    defer d.deinit();
    var hi = s.greeter();
    defer hi.deinit();
    const g = hi.call("volt");
    defer g.deinit();
    print("{d} {s}\n", .{ d.call(21), g.bytes() });
    lists();
}
