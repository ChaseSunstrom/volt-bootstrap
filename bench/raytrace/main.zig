// raytrace: spheres on a ground sphere, one light with shadows and a highlight, mirror bounces, one
// ray per pixel; prints a checksum of the 8-bit pixels. Zig gives a Vec3 struct add/sub/scale/dot methods
const std = @import("std");

const Vec3 = struct {
    x: f64,
    y: f64,
    z: f64,

    fn init(x: f64, y: f64, z: f64) Vec3 {
        return .{ .x = x, .y = y, .z = z };
    }
    fn add(a: Vec3, b: Vec3) Vec3 {
        return .init(a.x + b.x, a.y + b.y, a.z + b.z);
    }
    fn sub(a: Vec3, b: Vec3) Vec3 {
        return .init(a.x - b.x, a.y - b.y, a.z - b.z);
    }
    fn scale(a: Vec3, k: f64) Vec3 {
        return .init(a.x * k, a.y * k, a.z * k);
    }
    fn dot(a: Vec3, b: Vec3) f64 {
        return a.x * b.x + a.y * b.y + a.z * b.z;
    }
    fn cross(a: Vec3, b: Vec3) Vec3 {
        return .init(a.y * b.z - a.z * b.y, a.z * b.x - a.x * b.z, a.x * b.y - a.y * b.x);
    }
    fn normalize(a: Vec3) Vec3 {
        return a.scale(1.0 / @sqrt(a.dot(a)));
    }
};

const MAX_DEPTH = 4;
const EPS = 1e-4;
const FAR = 1e30;
const light: Vec3 = .init(-6.0, 10.0, 4.0);
const white: Vec3 = .init(1.0, 1.0, 1.0);

const Sphere = struct {
    center: Vec3,
    color: Vec3,
    radius: f64,
    reflect: f64,

    // distance along the ray to the sphere, or FAR
    fn hit(s: *const Sphere, o: Vec3, d: Vec3) f64 {
        const oc = o.sub(s.center);
        const b = oc.dot(d);
        const c = oc.dot(oc) - s.radius * s.radius;
        const disc = b * b - c;
        if (disc < 0.0) return FAR;
        const sq = @sqrt(disc);
        var t = -b - sq;
        if (t > EPS) return t;
        t = -b + sq;
        if (t > EPS) return t;
        return FAR;
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

fn trace(spheres: []const Sphere, o: Vec3, d: Vec3, depth: u32) Vec3 {
    var best: f64 = FAR;
    var hit: ?*const Sphere = null;
    for (spheres) |*sp| {
        const t = sp.hit(o, d);
        if (t < best) {
            best = t;
            hit = sp;
        }
    }
    const s = hit orelse {
        const t = 0.5 * (d.y + 1.0);
        return white.scale(1.0 - t).add(Vec3.init(0.5, 0.7, 1.0).scale(t));
    };
    const p = o.add(d.scale(best));
    const nrm = p.sub(s.center).normalize();
    const to_light = light.sub(p);
    const dist = @sqrt(to_light.dot(to_light));
    const l = to_light.scale(1.0 / dist);
    var diffuse = nrm.dot(l);
    if (diffuse < 0.0) diffuse = 0.0;
    const start = p.add(nrm.scale(EPS));
    if (diffuse > 0.0) {
        for (spheres) |*sp| {
            if (sp.hit(start, l) < dist) {
                diffuse = 0.0;
                break;
            }
        }
    }
    var spec: f64 = 0.0;
    if (diffuse > 0.0) {
        spec = nrm.dot(l.sub(d).normalize());
        for (0..5) |_| spec *= spec;
    }
    var color = s.color.scale(0.1 + 0.9 * diffuse).add(white.scale(0.5 * spec));
    if (depth < MAX_DEPTH and s.reflect > 0.0) {
        const r = d.sub(nrm.scale(2.0 * d.dot(nrm)));
        color = color.scale(1.0 - s.reflect).add(trace(spheres, start, r, depth + 1).scale(s.reflect));
    }
    return color;
}

fn quantize(c: f64) u64 {
    return @intFromFloat(std.math.clamp(c, 0.0, 1.0) * 255.0);
}

pub fn main(init: std.process.Init) !void {
    var args = init.minimal.args.iterate();
    _ = args.skip();
    const width: u32 = if (args.next()) |s| try std.fmt.parseInt(u32, s, 10) else 2048;
    const height = width * 3 / 4;
    var spheres: [65]Sphere = undefined;
    spheres[0] = .{ .center = .init(0.0, -1000.0, 0.0), .color = .init(0.5, 0.5, 0.5), .radius = 1000.0, .reflect = 0.25 };
    for (spheres[1..]) |*sp| {
        const r = 0.2 + 0.4 * rand01();
        const x = -6.0 + 12.0 * rand01();
        const z = -1.0 - 12.0 * rand01();
        const cr = rand01();
        const cg = rand01();
        const cb = rand01();
        const reflect: f64 = if (rand01() < 0.3) 0.6 else 0.0;
        sp.* = .{ .center = .init(x, r, z), .color = .init(cr, cg, cb), .radius = r, .reflect = reflect };
    }
    const eye: Vec3 = .init(0.0, 2.0, 5.0);
    const forward = Vec3.init(0.0, 0.5, -5.0).sub(eye).normalize();
    const right = forward.cross(.init(0.0, 1.0, 0.0)).normalize();
    const up = right.cross(forward);
    const w: f64 = @floatFromInt(width);
    const h: f64 = @floatFromInt(height);
    const aspect = w / h;
    var check: u64 = 0;
    for (0..height) |py| {
        for (0..width) |px| {
            const u = (2.0 * (@as(f64, @floatFromInt(px)) + 0.5) / w - 1.0) * aspect * 0.6;
            const v = (1.0 - 2.0 * (@as(f64, @floatFromInt(py)) + 0.5) / h) * 0.6;
            const d = forward.add(right.scale(u)).add(up.scale(v)).normalize();
            const c = trace(&spheres, eye, d, 0);
            for ([_]f64{ c.x, c.y, c.z }) |q| check = check *% 31 +% quantize(q);
        }
    }
    var buf: [256]u8 = undefined;
    var fw = std.Io.File.stdout().writer(init.io, &buf);
    try fw.interface.print("{d}x{d} {d}\n", .{ width, height, check });
    try fw.interface.flush();
}
