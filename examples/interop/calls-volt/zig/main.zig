// Zig calls the Volt library greet through its Zig file (bindings/greet.zig): owned text comes back
// as VoltText (deinit frees it), an export struct is a type with deinit
const std = @import("std");
const greet = @import("greet.zig");

pub fn main() void {
    std.debug.print("add {d}\n", .{greet.add(2, 3)});
    const h = greet.hello("volt");
    defer h.deinit();
    std.debug.print("{s}\n", .{h.bytes()});
    const c = greet.tally.new("clicks");
    defer c.deinit();
    _ = c.add(1);
    const n = c.add(2);
    std.debug.print("{s} {d}\n", .{ c.name(), n });
}
