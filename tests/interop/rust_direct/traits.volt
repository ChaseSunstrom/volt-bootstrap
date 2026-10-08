use std::io;
use std::string;
// Rust traits both ways: Rust's trait objects as values with the trait's methods (and Rust's types
// attaching the trait), Volt's types attaching it passed where Rust takes one, lent or kept
use { "geom" } as geom;

struct tri {
    b: f64;
    h: f64;
}

attach geom::Shape -> tri {
    fn area(this) -> f64 { return this.b * this.h / 2.0; }
    fn name(this) -> std::string { return std::string::from("tri"); }
    fn label(this) -> str { return "T"; }
    fn grow(this, by: f64) -> void {
        this.b += by;
        this.h += by;
    }
}

// counts its drops: a value Rust keeps is freed when Rust drops it
var drops = 0;

struct blob {
    n: i32;
}

attach geom::Shape -> blob {
    fn area(this) -> f64 { return @cast<f64>(this.n); }
    fn name(this) -> std::string { return std::string::from("blob"); }
    fn label(this) -> str { return "B"; }
    fn grow(this, by: f64) -> void { this.n += 1; }
    fn describe(this) -> std::string { return std::string::from("a blob of its own"); }
}

attach fn delete(this: blob&) -> void {
    drops += 1;
}

fn main() -> void {
    var t: tri = { b: 4.0, h: 3.0 };
    std::println("area {} larger {}", geom::area_of(&t), geom::larger(&t, &t));
    geom::grow_twice(&t, 1.0);
    std::println("grown {}", geom::area_of(&t));
    std::println("{}", geom::describe_it(t));
    std::println("{}", geom::describe_it({ n: 5 } as blob));
    var c = geom::circle_of(1.0);
    c.grow(1.0);
    {
        val u = geom::unit_square();
        std::println("rust {} {} {} {}", u.area(), u.describe(), c.name(), c.area());
    }
    var k: geom::Circle = { r: 2.0 };
    std::println("circle {} {}", k.area(), k.label());
    var sh: geom::Shape = move c;
    std::println("union {}", geom::area_of(&sh));
    {
        var canvas = geom::Canvas::new();
        canvas.add({ b: 2.0, h: 2.0 } as tri);
        canvas.add({ n: 7 } as blob);
        canvas.add(geom::Square::new(3.0));
        std::println("canvas {} {}", canvas.total(), canvas.names());
    }
    std::println("drops {} squares {}", drops, geom::squares_dropped());
}
