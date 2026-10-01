use crate::Point;

/// a shape with private fields: Volt holds it as a handle
#[derive(Clone, Debug)]
pub struct Shape {
    name: String,
    sides: Vec<f64>,
}

impl Shape {
    pub fn new(name: &str) -> Self {
        Shape { name: name.to_string(), sides: Vec::new() }
    }

    pub fn add_side(&mut self, len: f64) {
        self.sides.push(len);
    }

    pub fn perimeter(&self) -> f64 {
        self.sides.iter().sum()
    }

    pub fn name(&self) -> &str {
        &self.name
    }

    pub fn side(&self, i: usize) -> Result<f64, String> {
        self.sides.get(i).copied().ok_or_else(|| format!("{} has no side {i}", self.name))
    }

    pub fn into_name(self) -> String {
        self.name
    }
}

/// a counter that can't be cloned: Volt can move it but not copy it
pub struct Counter {
    n: u64,
}

impl Counter {
    pub fn new() -> Counter {
        Counter { n: 0 }
    }

    pub fn tick(&mut self) -> u64 {
        self.n += 1;
        self.n
    }
}

pub fn longest(a: &Shape, b: &Shape) -> String {
    if a.perimeter() >= b.perimeter() { a.name().to_string() } else { b.name().to_string() }
}

pub fn centroid(points: &[f64]) -> Point {
    let n = (points.len() / 2).max(1) as f64;
    let (mut x, mut y) = (0.0, 0.0);
    for p in points.chunks(2) {
        x += p[0];
        y += p.get(1).copied().unwrap_or(0.0);
    }
    Point { x: x / n, y: y / n }
}

pub fn consume(s: Shape) -> usize {
    s.sides.len()
}
