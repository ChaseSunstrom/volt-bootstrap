// shapes: a million shapes of four kinds, their total area and perimeter summed over many rounds
// through dynamic dispatch; Volt's four structs attach a trait, and a std::vec of the trait holds
// them inline as a tagged union (a call is a switch on the tag, no vtable, no allocation per shape)
use std::io;
use std::math;
use std::text;

val PI = 3.141592653589793;

trait shape {
    fn area(this) -> f64;
    fn perimeter(this) -> f64;
}

fn dist(ax: f64, ay: f64, bx: f64, by: f64) -> f64 {
    val dx = bx - ax;
    val dy = by - ay;
    return std::math::sqrt(dx * dx + dy * dy);
}

struct circle {
    r: f64;
}

attach shape -> circle {
    fn area(this) -> f64 {
        return PI * this.r * this.r;
    }
    fn perimeter(this) -> f64 {
        return 2.0 * PI * this.r;
    }
}

struct rect {
    w: f64;
    h: f64;
}

attach shape -> rect {
    fn area(this) -> f64 {
        return this.w * this.h;
    }
    fn perimeter(this) -> f64 {
        return 2.0 * (this.w + this.h);
    }
}

struct triangle {
    x0: f64;
    y0: f64;
    x1: f64;
    y1: f64;
    x2: f64;
    y2: f64;
}

attach shape -> triangle {
    fn area(this) -> f64 {
        return 0.5 * ((this.x1 - this.x0) * (this.y2 - this.y0) - (this.x2 - this.x0) * (this.y1 - this.y0));
    }
    fn perimeter(this) -> f64 {
        return dist(this.x0, this.y0, this.x1, this.y1) + dist(this.x1, this.y1, this.x2, this.y2) + dist(this.x2, this.y2, this.x0, this.y0);
    }
}

struct quad {
    x: f64[4];
    y: f64[4];
}

attach shape -> quad {
    fn area(this) -> f64 {
        var sum = 0.0;
        for (i) in 0..4 {
            val j = (i + 1) % 4;
            sum += this.x[i] * this.y[j] - this.x[j] * this.y[i];
        }
        return 0.5 * sum;
    }
    fn perimeter(this) -> f64 {
        var sum = 0.0;
        for (i) in 0..4 {
            val j = (i + 1) % 4;
            sum += dist(this.x[i], this.y[i], this.x[j], this.y[j]);
        }
        return sum;
    }
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

fn make_shape() -> shape {
    match (next() % 4) {
        0 => {
            val c: circle = { r: 0.5 + 2.0 * rand01() };
            return c;
        },
        1 => {
            val r: rect = { w: 0.5 + 3.0 * rand01(), h: 0.5 + 3.0 * rand01() };
            return r;
        },
        2 => {
            val x = 10.0 * rand01();
            val y = 10.0 * rand01();
            val a = 0.5 + 2.0 * rand01();
            val b = 2.0 * rand01();
            val c = 0.5 + 2.0 * rand01();
            val t: triangle = { x0: x, y0: y, x1: x + a, y1: y, x2: x + b, y2: y + c };
            return t;
        },
        default => {
            val cx = 10.0 * rand01();
            val cy = 10.0 * rand01();
            val a = 0.5 + 1.5 * rand01();
            val b = 0.5 + 1.5 * rand01();
            val c = 0.5 + 1.5 * rand01();
            val d = 0.5 + 1.5 * rand01();
            val q: quad = { x: { cx + a, cx, cx - c, cx }, y: { cy, cy + b, cy, cy - d } };
            return q;
        },
    }
}

fn main() -> !void {
    val rounds = (std::process::arg(1) ?? "100").parse_int() catch 100;
    val n: usize = 1000000;
    var shapes: std::vec<shape> = {};
    try shapes.reserve(n);
    for (i) in 0..n {
        try shapes.push(make_shape());
    }
    var area = 0.0;
    var perimeter = 0.0;
    for (r) in 0..rounds {
        for (s&) in shapes.items() {
            area += s.area();
            perimeter += s.perimeter();
        }
    }
    std::println("{} {}", @cast<i64>(area), @cast<i64>(perimeter));
}
