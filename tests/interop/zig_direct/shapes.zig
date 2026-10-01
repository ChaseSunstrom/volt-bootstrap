const std = @import("std");

/// a shape that owns memory: Volt holds it as a handle, and delete calls deinit
pub const Shape = struct {
    name: []u8,
    sides: std.ArrayList(f64),

    pub fn init(allocator: std.mem.Allocator, name: []const u8) !Shape {
        return .{ .name = try allocator.dupe(u8, name), .sides = .empty };
    }

    pub fn deinit(self: *Shape, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        self.sides.deinit(allocator);
    }

    pub fn addSide(self: *Shape, allocator: std.mem.Allocator, len: f64) !void {
        try self.sides.append(allocator, len);
    }

    pub fn perimeter(self: *const Shape) f64 {
        var t: f64 = 0;
        for (self.sides.items) |x| t += x;
        return t;
    }

    pub fn getName(self: *const Shape) []const u8 {
        return self.name;
    }

    /// takes the shape (by value) and frees it: Volt's handle is left empty
    pub fn consume(self: Shape, allocator: std.mem.Allocator) usize {
        var s = self;
        defer s.deinit(allocator);
        return s.sides.items.len;
    }

    pub fn side(self: *const Shape, i: usize) error{NoSuchSide}!f64 {
        if (i >= self.sides.items.len) return error.NoSuchSide;
        return self.sides.items[i];
    }
};

/// no deinit: Volt can copy it
pub const Counter = struct {
    n: u64 = 0,
    label: []const u8,

    pub fn init(label: []const u8) Counter {
        return .{ .label = label };
    }

    pub fn tick(self: *Counter) u64 {
        self.n += 1;
        return self.n;
    }
};

pub fn longest(a: *const Shape, b: *const Shape) []const u8 {
    return if (a.perimeter() >= b.perimeter()) a.name else b.name;
}
