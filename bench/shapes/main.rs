// shapes: a million shapes of four kinds, their total area and perimeter summed over many rounds
// through dynamic dispatch; Rust implements a trait for four structs and keeps them in a
// Vec<Box<dyn Shape>>
use std::f64::consts::PI;

trait Shape {
    fn area(&self) -> f64;
    fn perimeter(&self) -> f64;
}

fn dist(ax: f64, ay: f64, bx: f64, by: f64) -> f64 {
    let (dx, dy) = (bx - ax, by - ay);
    (dx * dx + dy * dy).sqrt()
}

struct Circle {
    r: f64,
}

impl Shape for Circle {
    fn area(&self) -> f64 {
        PI * self.r * self.r
    }
    fn perimeter(&self) -> f64 {
        2.0 * PI * self.r
    }
}

struct Rect {
    w: f64,
    h: f64,
}

impl Shape for Rect {
    fn area(&self) -> f64 {
        self.w * self.h
    }
    fn perimeter(&self) -> f64 {
        2.0 * (self.w + self.h)
    }
}

struct Triangle {
    x0: f64,
    y0: f64,
    x1: f64,
    y1: f64,
    x2: f64,
    y2: f64,
}

impl Shape for Triangle {
    fn area(&self) -> f64 {
        0.5 * ((self.x1 - self.x0) * (self.y2 - self.y0) - (self.x2 - self.x0) * (self.y1 - self.y0))
    }
    fn perimeter(&self) -> f64 {
        dist(self.x0, self.y0, self.x1, self.y1) + dist(self.x1, self.y1, self.x2, self.y2) + dist(self.x2, self.y2, self.x0, self.y0)
    }
}

struct Quad {
    x: [f64; 4],
    y: [f64; 4],
}

impl Shape for Quad {
    fn area(&self) -> f64 {
        let mut sum = 0.0;
        for i in 0..4 {
            let j = (i + 1) % 4;
            sum += self.x[i] * self.y[j] - self.x[j] * self.y[i];
        }
        0.5 * sum
    }
    fn perimeter(&self) -> f64 {
        let mut sum = 0.0;
        for i in 0..4 {
            let j = (i + 1) % 4;
            sum += dist(self.x[i], self.y[i], self.x[j], self.y[j]);
        }
        sum
    }
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

fn make_shape(rng: &mut Rng) -> Box<dyn Shape> {
    match rng.next() % 4 {
        0 => Box::new(Circle { r: 0.5 + 2.0 * rng.rand01() }),
        1 => {
            let w = 0.5 + 3.0 * rng.rand01();
            let h = 0.5 + 3.0 * rng.rand01();
            Box::new(Rect { w, h })
        }
        2 => {
            let x = 10.0 * rng.rand01();
            let y = 10.0 * rng.rand01();
            let a = 0.5 + 2.0 * rng.rand01();
            let b = 2.0 * rng.rand01();
            let c = 0.5 + 2.0 * rng.rand01();
            Box::new(Triangle { x0: x, y0: y, x1: x + a, y1: y, x2: x + b, y2: y + c })
        }
        _ => {
            let cx = 10.0 * rng.rand01();
            let cy = 10.0 * rng.rand01();
            let a = 0.5 + 1.5 * rng.rand01();
            let b = 0.5 + 1.5 * rng.rand01();
            let c = 0.5 + 1.5 * rng.rand01();
            let d = 0.5 + 1.5 * rng.rand01();
            Box::new(Quad { x: [cx + a, cx, cx - c, cx], y: [cy, cy + b, cy, cy - d] })
        }
    }
}

fn main() {
    let rounds: u64 = std::env::args().nth(1).and_then(|a| a.parse().ok()).unwrap_or(100);
    let mut rng = Rng(88172645463325252);
    let shapes: Vec<Box<dyn Shape>> = (0..1000000).map(|_| make_shape(&mut rng)).collect();
    let (mut area, mut perimeter) = (0.0, 0.0);
    for _ in 0..rounds {
        for s in &shapes {
            area += s.area();
            perimeter += s.perimeter();
        }
    }
    println!("{} {}", area as i64, perimeter as i64);
}
