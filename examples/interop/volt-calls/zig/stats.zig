// stats.zig: ordinary Zig, nothing written for Volt; main.volt imports it
const std = @import("std");

pub const Point = struct {
    x: f64,
    y: f64,

    pub fn norm(self: Point) f64 {
        return @sqrt(self.x * self.x + self.y * self.y);
    }
};

pub fn mean(xs: []const f64) f64 {
    if (xs.len == 0) return 0;
    var total: f64 = 0;
    for (xs) |x| total += x;
    return total / @as(f64, @floatFromInt(xs.len));
}

pub fn divide(a: i64, b: i64) !i64 {
    if (b == 0) return error.DivisionByZero;
    return @divTrunc(a, b);
}
