// Zig calls the Volt library through voltc bindings --lang zig: errors come back as Error, owned
// text as VoltText (deinit frees it), an export struct is a type with deinit
const std = @import("std");
const m = @import("mathlib.zig");
const print = std.debug.print;

const Sum = struct { total: i32 = 0 };

fn add_up(s: *Sum, x: i32) void {
    s.total += x;
    print(" {d}", .{x});
}

pub fn main() void {
    print("add {d}\n", .{m.ml_add(2, 3)});
    var a = m.vec2{ .x = 1, .y = 2 };
    const b = m.vec2{ .x = 3, .y = 4 };
    print("dot {d}\n", .{m.ml_dot(a, b)});
    m.ml_scale(&a, 2);
    print("scale {d} {d}\n", .{ a.x, a.y });
    print("len {d}\n", .{m.ml_len("hello")});
    print("clash {d}\n", .{m.ml_clash(1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, "ab", 13, 14)});
    var tg = m.ml_tags_make();
    const head = .{ tg.from, tg.@"type", tg.self, tg.int };
    tg.int = 5;
    print("tags {d} {d} {d} {d} {d}\n", .{ head[0], head[1], head[2], head[3], m.ml_tags_sum(tg) });
    var bp: i32 = 7;
    var bq: f64 = 2.5;
    m.ml_bump(&bp, &bq);
    print("bump {d} {d}\n", .{ bp, bq });
    print("next {d}\n", .{@intFromEnum(m.ml_next(m.color.GREEN))});
    print("sqrt {d} 1\n", .{m.ml_sqrt(9) catch unreachable});
    if (m.ml_sqrt(-1)) |_| {} else |e| print("error {s}\n", .{if (e == error.NEGATIVE) "negative" else "?"});
    const g = m.ml_greet("volt");
    defer g.deinit();
    print("greet {s}\n", .{g.bytes()});
    const rp = m.ml_repeat("ab", 2) catch unreachable;
    defer rp.deinit();
    print("repeat {s}\n", .{rp.bytes()});
    if (m.ml_repeat("ab", -1)) |t| t.deinit() else |e| print("repeat {s}\n", .{if (e == error.NEGATIVE) "negative" else "?"});
    var xs = [_]f64{ 1, 2, 3.5 };
    print("sum {d}\n", .{m.ml_sum(&xs)});
    var ys = [_]i32{ 4, 5, 6 };
    print("find {d} {s}\n", .{ m.ml_find(&ys, 6).?, if (m.ml_find(&ys, 9) == null) "none" else "?" });
    var s = Sum{};
    print("each", .{});
    m.ml_each(&ys, &s, add_up);
    print(" = {d}\n", .{s.total});
    const c = m.counter.new("clicks");
    defer c.deinit();
    _ = c.add(2);
    print("counter {s} {d}\n", .{ c.name(), c.add(3) });
    if (c.take(9)) |_| {} else |e| print("take {s}\n", .{if (e == error.NEGATIVE) "negative" else "?"});
}
