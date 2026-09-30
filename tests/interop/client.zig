// Zig calls the Volt library through voltc bindings --lang zig
const std = @import("std");
const m = @import("mathlib.zig");

pub fn main() void {
    std.debug.print("add {d}\n", .{m.ml_add(2, 3)});
    var a = m.vec2{ .x = 1, .y = 2 };
    const b = m.vec2{ .x = 3, .y = 4 };
    std.debug.print("dot {d}\n", .{m.ml_dot(a, b)});
    m.ml_scale(&a, 2);
    std.debug.print("scale {d} {d}\n", .{ a.x, a.y });
    std.debug.print("len {d}\n", .{m.ml_len(m.VoltStr.from("hello"))});
    std.debug.print("next {d}\n", .{@intFromEnum(m.ml_next(m.color.GREEN))});
    const r = m.ml_sqrt(9);
    std.debug.print("sqrt {d} {d}\n", .{ r.value, @intFromBool(r.@"error" == 0) });
    const e = m.ml_sqrt(-1);
    std.debug.print("error {s}\n", .{if (e.@"error" == m.math_error.NEGATIVE) "negative" else "?"});
}
