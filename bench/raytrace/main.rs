// raytrace: spheres on a ground sphere, one light with shadows and a highlight, mirror bounces, one
// ray per pixel; prints a checksum of the 8-bit pixels. Rust implements + - * on a Copy Vec3 struct
use std::ops::{Add, Mul, Sub};

#[derive(Clone, Copy)]
struct Vec3 {
    x: f64,
    y: f64,
    z: f64,
}

const fn v3(x: f64, y: f64, z: f64) -> Vec3 {
    Vec3 { x, y, z }
}

impl Add for Vec3 {
    type Output = Vec3;
    fn add(self, b: Vec3) -> Vec3 {
        v3(self.x + b.x, self.y + b.y, self.z + b.z)
    }
}

impl Sub for Vec3 {
    type Output = Vec3;
    fn sub(self, b: Vec3) -> Vec3 {
        v3(self.x - b.x, self.y - b.y, self.z - b.z)
    }
}

impl Mul<f64> for Vec3 {
    type Output = Vec3;
    fn mul(self, k: f64) -> Vec3 {
        v3(self.x * k, self.y * k, self.z * k)
    }
}

impl Vec3 {
    fn dot(self, b: Vec3) -> f64 {
        self.x * b.x + self.y * b.y + self.z * b.z
    }
    fn cross(self, b: Vec3) -> Vec3 {
        v3(self.y * b.z - self.z * b.y, self.z * b.x - self.x * b.z, self.x * b.y - self.y * b.x)
    }
    fn normalize(self) -> Vec3 {
        self * (1.0 / self.dot(self).sqrt())
    }
}

struct Sphere {
    center: Vec3,
    color: Vec3,
    radius: f64,
    reflect: f64,
}

struct Rng(u64);

impl Rng {
    fn next(&mut self) -> u64 {
        self.0 ^= self.0 << 13;
        self.0 ^= self.0 >> 7;
        self.0 ^= self.0 << 17;
        self.0
    }
    fn rand01(&mut self) -> f64 {
        (self.next() >> 11) as f64 / 9007199254740992.0
    }
}

const MAX_DEPTH: i32 = 4;
const EPS: f64 = 1e-4;
const FAR: f64 = 1e30;
const LIGHT: Vec3 = v3(-6.0, 10.0, 4.0);

impl Sphere {
    // distance along the ray to the sphere, or FAR
    fn hit(&self, o: Vec3, d: Vec3) -> f64 {
        let oc = o - self.center;
        let b = oc.dot(d);
        let c = oc.dot(oc) - self.radius * self.radius;
        let disc = b * b - c;
        if disc < 0.0 {
            return FAR;
        }
        let sq = disc.sqrt();
        let t = -b - sq;
        if t > EPS {
            return t;
        }
        let t = -b + sq;
        if t > EPS {
            return t;
        }
        FAR
    }
}

fn trace(spheres: &[Sphere], o: Vec3, d: Vec3, depth: i32) -> Vec3 {
    let mut best = FAR;
    let mut hit = None;
    for s in spheres {
        let t = s.hit(o, d);
        if t < best {
            best = t;
            hit = Some(s);
        }
    }
    let Some(s) = hit else {
        let t = 0.5 * (d.y + 1.0);
        return v3(1.0, 1.0, 1.0) * (1.0 - t) + v3(0.5, 0.7, 1.0) * t;
    };
    let p = o + d * best;
    let nrm = (p - s.center).normalize();
    let to_light = LIGHT - p;
    let dist = to_light.dot(to_light).sqrt();
    let l = to_light * (1.0 / dist);
    let mut diffuse = nrm.dot(l).max(0.0);
    let start = p + nrm * EPS;
    if diffuse > 0.0 && spheres.iter().any(|t| t.hit(start, l) < dist) {
        diffuse = 0.0;
    }
    let mut spec = 0.0;
    if diffuse > 0.0 {
        spec = nrm.dot((l - d).normalize());
        for _ in 0..5 {
            spec *= spec;
        }
    }
    let mut color = s.color * (0.1 + 0.9 * diffuse) + v3(1.0, 1.0, 1.0) * (0.5 * spec);
    if depth < MAX_DEPTH && s.reflect > 0.0 {
        let r = d - nrm * (2.0 * d.dot(nrm));
        color = color * (1.0 - s.reflect) + trace(spheres, start, r, depth + 1) * s.reflect;
    }
    color
}

fn quantize(c: f64) -> u64 {
    (c.clamp(0.0, 1.0) * 255.0) as u64
}

fn main() {
    let width: i32 = std::env::args().nth(1).and_then(|a| a.parse().ok()).unwrap_or(2048);
    let height = width * 3 / 4;
    let mut rng = Rng(88172645463325252);
    let mut spheres = vec![Sphere { center: v3(0.0, -1000.0, 0.0), color: v3(0.5, 0.5, 0.5), radius: 1000.0, reflect: 0.25 }];
    for _ in 0..64 {
        let r = 0.2 + 0.4 * rng.rand01();
        let x = -6.0 + 12.0 * rng.rand01();
        let z = -1.0 - 12.0 * rng.rand01();
        let (cr, cg, cb) = (rng.rand01(), rng.rand01(), rng.rand01());
        let reflect = if rng.rand01() < 0.3 { 0.6 } else { 0.0 };
        spheres.push(Sphere { center: v3(x, r, z), color: v3(cr, cg, cb), radius: r, reflect });
    }
    let eye = v3(0.0, 2.0, 5.0);
    let forward = (v3(0.0, 0.5, -5.0) - eye).normalize();
    let right = forward.cross(v3(0.0, 1.0, 0.0)).normalize();
    let up = right.cross(forward);
    let aspect = width as f64 / height as f64;
    let mut check = 0u64;
    for py in 0..height {
        for px in 0..width {
            let u = (2.0 * (px as f64 + 0.5) / width as f64 - 1.0) * aspect * 0.6;
            let v = (1.0 - 2.0 * (py as f64 + 0.5) / height as f64) * 0.6;
            let d = (forward + right * u + up * v).normalize();
            let c = trace(&spheres, eye, d, 0);
            for q in [c.x, c.y, c.z] {
                check = check.wrapping_mul(31).wrapping_add(quantize(q));
            }
        }
    }
    println!("{width}x{height} {check}");
}
