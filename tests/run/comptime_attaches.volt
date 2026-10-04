// @attaches(T, trait): does T attach the trait? A compile-time bool, so a template can use what a type
// offers and leave out what it doesn't
use std::io;

trait measured {
    fn area(this) -> f64;
}

trait named {
    fn name(this) -> str;
}

<T: type>
trait source {
    fn next(this) -> T?;
}

struct circle { r: f64; }
struct square { side: f64; }

attach measured -> circle {
    fn area(this) -> f64 { return 3.0 * this.r * this.r; }
}

attach measured -> square {
    fn area(this) -> f64 { return this.side * this.side; }
}

attach named -> square {
    fn name(this) -> str { return "square"; }
}

attach source<i32> -> circle {
    fn next(this) -> i32? { return null; }
}

<T: type>
fn describe(s: T&) -> void {
    comptime if (@attaches(T, named)) {
        std::println("{}: {}", s.name(), s.area());
    } else {
        std::println("something: {}", s.area());
    }
}

fn main() -> void {
    val c: circle = { r: 1.0 };
    val q: square = { side: 2.0 };
    describe(&c);
    describe(&q);
    std::println("{} {} {}", @attaches(circle, measured), @attaches(circle, named), @attaches(i32, measured));
    std::println("{} {}", @attaches(circle, source<i32>), @attaches(circle, source<i64>));
}
// expect: something: 3
// expect: square: 4
// expect: true false false
// expect: true false
