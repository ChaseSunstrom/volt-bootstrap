// raytrace: spheres on a ground sphere, one light with shadows and a highlight, mirror bounces, one
// ray per pixel; prints a checksum of the 8-bit pixels. Volt attaches + - * to a vec3 struct
use std::io;
use std::math;
use std::text;

struct vec3 {
    x: f64;
    y: f64;
    z: f64;
}

attach operator +(this: vec3, o: vec3) -> vec3 {
    return { x: this.x + o.x, y: this.y + o.y, z: this.z + o.z };
}

attach operator -(this: vec3, o: vec3) -> vec3 {
    return { x: this.x - o.x, y: this.y - o.y, z: this.z - o.z };
}

attach operator *(this: vec3, k: f64) -> vec3 {
    return { x: this.x * k, y: this.y * k, z: this.z * k };
}

attach fn dot(this: vec3, o: vec3) -> f64 {
    return this.x * o.x + this.y * o.y + this.z * o.z;
}

attach fn cross(this: vec3, o: vec3) -> vec3 {
    return { x: this.y * o.z - this.z * o.y, y: this.z * o.x - this.x * o.z, z: this.x * o.y - this.y * o.x };
}

attach fn normalize(this: vec3) -> vec3 {
    return this * (1.0 / std::math::sqrt(this.dot(this)));
}

struct sphere {
    center: vec3;
    color: vec3;
    radius: f64;
    reflect: f64;
}

var rng: u64 = 88172645463325252;

fn next() -> u64 {
    rng = rng ^ (rng << 13);
    rng = rng ^ (rng >> 7);
    rng = rng ^ (rng << 17);
    return rng;
}

fn rand01() -> f64 {
    return @cast<f64>(next() >> 11) / 9007199254740992.0;
}

val MAX_DEPTH = 4;
val EPS = 1e-4;
val FAR = 1e30;
val light: vec3 = { x: -6.0, y: 10.0, z: 4.0 };
val white: vec3 = { x: 1.0, y: 1.0, z: 1.0 };
val sky: vec3 = { x: 0.5, y: 0.7, z: 1.0 };

// distance along the ray to the sphere, or FAR
fn hit(s: sphere&, o: vec3, d: vec3) -> f64 {
    val oc = o - s.center;
    val b = oc.dot(d);
    val c = oc.dot(oc) - s.radius * s.radius;
    val disc = b * b - c;
    if (disc < 0.0) {
        return FAR;
    }
    val sq = std::math::sqrt(disc);
    var t = -b - sq;
    if (t > EPS) {
        return t;
    }
    t = -b + sq;
    if (t > EPS) {
        return t;
    }
    return FAR;
}

fn background(d: vec3) -> vec3 {
    val t = 0.5 * (d.y + 1.0);
    return white * (1.0 - t) + sky * t;
}

fn trace(spheres: sphere[..], o: vec3, d: vec3, depth: i32) -> vec3 {
    var best = FAR;
    var nearest: sphere* = null;
    for (sp&) in spheres {
        val t = hit(sp, o, d);
        if (t < best) {
            best = t;
            nearest = sp;
        }
    }
    val s = nearest ?? return background(d);
    val p = o + d * best;
    val n = (p - s.center).normalize();
    val to_light = light - p;
    val dist = std::math::sqrt(to_light.dot(to_light));
    val l = to_light * (1.0 / dist);
    var diffuse = n.dot(l);
    if (diffuse < 0.0) {
        diffuse = 0.0;
    }
    val start = p + n * EPS;
    if (diffuse > 0.0) {
        for (sp&) in spheres {
            if (hit(sp, start, l) < dist) {
                diffuse = 0.0;
                break;
            }
        }
    }
    var spec = 0.0;
    if (diffuse > 0.0) {
        spec = n.dot((l - d).normalize());
        for (k) in 0..5 {
            spec *= spec;
        }
    }
    var color = s.color * (0.1 + 0.9 * diffuse) + white * (0.5 * spec);
    if (depth < MAX_DEPTH && s.reflect > 0.0) {
        val r = d - n * (2.0 * d.dot(n));
        color = color * (1.0 - s.reflect) + trace(spheres, start, r, depth + 1) * s.reflect;
    }
    return color;
}

fn quantize(var c: f64) -> u64 {
    if (c < 0.0) {
        c = 0.0;
    }
    if (c > 1.0) {
        c = 1.0;
    }
    return @cast<u64>(@cast<i32>(c * 255.0));
}

fn main() -> !void {
    val width = (std::process::arg(1) ?? "2048").parse_int() catch 2048;
    val height = width * 3 / 4;
    var spheres: std::vec<sphere> = {};
    try spheres.push({ center: { x: 0.0, y: -1000.0, z: 0.0 }, color: { x: 0.5, y: 0.5, z: 0.5 }, radius: 1000.0, reflect: 0.25 });
    for (i) in 0..64 {
        val r = 0.2 + 0.4 * rand01();
        val x = -6.0 + 12.0 * rand01();
        val z = -1.0 - 12.0 * rand01();
        val color: vec3 = { x: rand01(), y: rand01(), z: rand01() };
        val reflect = if (rand01() < 0.3) 0.6 else 0.0;
        try spheres.push({ center: { x, y: r, z }, color, radius: r, reflect });
    }
    val eye: vec3 = { x: 0.0, y: 2.0, z: 5.0 };
    val target: vec3 = { x: 0.0, y: 0.5, z: -5.0 };
    val forward = (target - eye).normalize();
    val right = forward.cross({ x: 0.0, y: 1.0, z: 0.0 }).normalize();
    val up = right.cross(forward);
    val w = @cast<f64>(width);
    val h = @cast<f64>(height);
    val aspect = w / h;
    var check: u64 = 0;
    for (py) in 0..height {
        for (px) in 0..width {
            val u = (2.0 * (@cast<f64>(px) + 0.5) / w - 1.0) * aspect * 0.6;
            val v = (1.0 - 2.0 * (@cast<f64>(py) + 0.5) / h) * 0.6;
            val d = (forward + right * u + up * v).normalize();
            val c = trace(spheres.items(), eye, d, 0);
            check = check *% 31 +% quantize(c.x);
            check = check *% 31 +% quantize(c.y);
            check = check *% 31 +% quantize(c.z);
        }
    }
    std::println("{}x{} {}", width, height, check);
}
