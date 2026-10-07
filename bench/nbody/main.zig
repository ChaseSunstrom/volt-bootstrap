// n-body (the Benchmarks Game): the Jovian planets around the sun, simulated in steps
const std = @import("std");

const Body = struct { x: f64, y: f64, z: f64, vx: f64, vy: f64, vz: f64, mass: f64 };

const pi: f64 = 3.141592653589793;
const solar = 4 * pi * pi;
const days: f64 = 365.24;

fn energy(b: []const Body) f64 {
    var e: f64 = 0;
    for (b, 0..) |bi, i| {
        e += 0.5 * bi.mass * (bi.vx * bi.vx + bi.vy * bi.vy + bi.vz * bi.vz);
        for (b[i + 1 ..]) |bj| {
            const dx = bi.x - bj.x;
            const dy = bi.y - bj.y;
            const dz = bi.z - bj.z;
            e -= bi.mass * bj.mass / @sqrt(dx * dx + dy * dy + dz * dz);
        }
    }
    return e;
}

fn advance(b: []Body, dt: f64) void {
    for (b, 0..) |*bi, i| {
        for (b[i + 1 ..]) |*bj| {
            const dx = bi.x - bj.x;
            const dy = bi.y - bj.y;
            const dz = bi.z - bj.z;
            const d2 = dx * dx + dy * dy + dz * dz;
            const mag = dt / (d2 * @sqrt(d2));
            bi.vx -= dx * bj.mass * mag;
            bi.vy -= dy * bj.mass * mag;
            bi.vz -= dz * bj.mass * mag;
            bj.vx += dx * bi.mass * mag;
            bj.vy += dy * bi.mass * mag;
            bj.vz += dz * bi.mass * mag;
        }
    }
    for (b) |*bi| {
        bi.x += dt * bi.vx;
        bi.y += dt * bi.vy;
        bi.z += dt * bi.vz;
    }
}

fn planet(x: f64, y: f64, z: f64, vx: f64, vy: f64, vz: f64, mass: f64) Body {
    return .{ .x = x, .y = y, .z = z, .vx = vx * days, .vy = vy * days, .vz = vz * days, .mass = mass * solar };
}

pub fn main(init: std.process.Init) !void {
    var args = init.minimal.args.iterate();
    _ = args.skip();
    const steps: u32 = if (args.next()) |a| try std.fmt.parseInt(u32, a, 10) else 20000000;
    var b = [_]Body{
        .{ .x = 0, .y = 0, .z = 0, .vx = 0, .vy = 0, .vz = 0, .mass = solar },
        planet(4.84143144246472090e+00, -1.16032004402742839e+00, -1.03622044471123109e-01, 1.66007664274403694e-03, 7.69901118419740425e-03, -6.90460016972063023e-05, 9.54791938424326609e-04),
        planet(8.34336671824457987e+00, 4.12479856412430479e+00, -4.03523417114321381e-01, -2.76742510726862411e-03, 4.99852801234917238e-03, 2.30417297573763929e-05, 2.85885980666130812e-04),
        planet(1.28943695621391310e+01, -1.51111514016986312e+01, -2.23307578892655734e-01, 2.96460137564761618e-03, 2.37847173959480950e-03, -2.96589568540237556e-05, 4.36624404335156298e-05),
        planet(1.53796971148509165e+01, -2.59193146099879641e+01, 1.79258772950371181e-01, 2.68067772490389322e-03, 1.62824170038242295e-03, -9.51592254519715870e-05, 5.15138902046611451e-05),
    };
    var px: f64 = 0;
    var py: f64 = 0;
    var pz: f64 = 0;
    for (b) |bi| {
        px += bi.vx * bi.mass;
        py += bi.vy * bi.mass;
        pz += bi.vz * bi.mass;
    }
    b[0].vx = -px / solar;
    b[0].vy = -py / solar;
    b[0].vz = -pz / solar;
    var buf: [128]u8 = undefined;
    var w = std.Io.File.stdout().writer(init.io, &buf);
    try w.interface.print("{d:.9}\n", .{energy(&b)});
    for (0..steps) |_| advance(&b, 0.01);
    try w.interface.print("{d:.9}\n", .{energy(&b)});
    try w.interface.flush();
}
