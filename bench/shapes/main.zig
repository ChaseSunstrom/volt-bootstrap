// shapes: a million shapes of four kinds, their total area and perimeter summed over many rounds
// through dynamic dispatch; Zig gives four structs one interface (a pointer and a vtable, the way
// std.mem.Allocator does it) and keeps a slice of them, each created in the program's arena
const std = @import("std");
const pi = std.math.pi;

const Shape = struct {
    ptr: *const anyopaque,
    vtable: *const VTable,

    const VTable = struct {
        area: *const fn (*const anyopaque) f64,
        perimeter: *const fn (*const anyopaque) f64,
    };

    fn area(s: Shape) f64 {
        return s.vtable.area(s.ptr);
    }

    fn perimeter(s: Shape) f64 {
        return s.vtable.perimeter(s.ptr);
    }

    // the interface to a T that has area and perimeter methods
    fn of(comptime T: type, p: *const T) Shape {
        const gen = struct {
            fn areaOf(q: *const anyopaque) f64 {
                return T.area(@ptrCast(@alignCast(q)));
            }
            fn perimeterOf(q: *const anyopaque) f64 {
                return T.perimeter(@ptrCast(@alignCast(q)));
            }
            const vtable: VTable = .{ .area = areaOf, .perimeter = perimeterOf };
        };
        return .{ .ptr = p, .vtable = &gen.vtable };
    }
};

fn dist(ax: f64, ay: f64, bx: f64, by: f64) f64 {
    const dx = bx - ax;
    const dy = by - ay;
    return @sqrt(dx * dx + dy * dy);
}

const Circle = struct {
    r: f64,
    fn area(c: *const Circle) f64 {
        return pi * c.r * c.r;
    }
    fn perimeter(c: *const Circle) f64 {
        return 2.0 * pi * c.r;
    }
};

const Rect = struct {
    w: f64,
    h: f64,
    fn area(r: *const Rect) f64 {
        return r.w * r.h;
    }
    fn perimeter(r: *const Rect) f64 {
        return 2.0 * (r.w + r.h);
    }
};

const Triangle = struct {
    x0: f64,
    y0: f64,
    x1: f64,
    y1: f64,
    x2: f64,
    y2: f64,
    fn area(t: *const Triangle) f64 {
        return 0.5 * ((t.x1 - t.x0) * (t.y2 - t.y0) - (t.x2 - t.x0) * (t.y1 - t.y0));
    }
    fn perimeter(t: *const Triangle) f64 {
        return dist(t.x0, t.y0, t.x1, t.y1) + dist(t.x1, t.y1, t.x2, t.y2) + dist(t.x2, t.y2, t.x0, t.y0);
    }
};

const Quad = struct {
    x: [4]f64,
    y: [4]f64,
    fn area(q: *const Quad) f64 {
        var sum: f64 = 0.0;
        for (0..4) |i| {
            const j = (i + 1) % 4;
            sum += q.x[i] * q.y[j] - q.x[j] * q.y[i];
        }
        return 0.5 * sum;
    }
    fn perimeter(q: *const Quad) f64 {
        var sum: f64 = 0.0;
        for (0..4) |i| {
            const j = (i + 1) % 4;
            sum += dist(q.x[i], q.y[i], q.x[j], q.y[j]);
        }
        return sum;
    }
};

var rng: u64 = 88172645463325252;

fn next() u64 {
    rng ^= rng << 13;
    rng ^= rng >> 7;
    rng ^= rng << 17;
    return rng;
}

fn rand01() f64 {
    return @as(f64, @floatFromInt(next() >> 11)) / 9007199254740992.0;
}

fn new(gpa: std.mem.Allocator, value: anytype) !Shape {
    const p = try gpa.create(@TypeOf(value));
    p.* = value;
    return Shape.of(@TypeOf(value), p);
}

fn makeShape(gpa: std.mem.Allocator) !Shape {
    switch (next() % 4) {
        0 => return new(gpa, Circle{ .r = 0.5 + 2.0 * rand01() }),
        1 => {
            const w = 0.5 + 3.0 * rand01();
            const h = 0.5 + 3.0 * rand01();
            return new(gpa, Rect{ .w = w, .h = h });
        },
        2 => {
            const x0 = 10.0 * rand01();
            const y0 = 10.0 * rand01();
            const a = 0.5 + 2.0 * rand01();
            const b = 2.0 * rand01();
            const c = 0.5 + 2.0 * rand01();
            return new(gpa, Triangle{ .x0 = x0, .y0 = y0, .x1 = x0 + a, .y1 = y0, .x2 = x0 + b, .y2 = y0 + c });
        },
        else => {
            const cx = 10.0 * rand01();
            const cy = 10.0 * rand01();
            const a = 0.5 + 1.5 * rand01();
            const b = 0.5 + 1.5 * rand01();
            const c = 0.5 + 1.5 * rand01();
            const d = 0.5 + 1.5 * rand01();
            return new(gpa, Quad{ .x = .{ cx + a, cx, cx - c, cx }, .y = .{ cy, cy + b, cy, cy - d } });
        },
    }
}

pub fn main(init: std.process.Init) !void {
    var args = init.minimal.args.iterate();
    _ = args.skip();
    const rounds: u64 = if (args.next()) |s| try std.fmt.parseInt(u64, s, 10) else 100;
    // the shapes live as long as the program, so they come from its arena
    const arena = init.arena.allocator();
    const shapes = try arena.alloc(Shape, 1000000);
    for (shapes) |*s| s.* = try makeShape(arena);
    var area: f64 = 0.0;
    var perimeter: f64 = 0.0;
    for (0..rounds) |_| {
        for (shapes) |s| {
            area += s.area();
            perimeter += s.perimeter();
        }
    }
    var buf: [256]u8 = undefined;
    var fw = std.Io.File.stdout().writer(init.io, &buf);
    try fw.interface.print("{d} {d}\n", .{ @as(i64, @intFromFloat(area)), @as(i64, @intFromFloat(perimeter)) });
    try fw.interface.flush();
}
