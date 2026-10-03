// @attaches(T, trait): does T attach the trait? A compile-time bool, so a template can use what a type
// offers and leave out what it doesn't
use std::io;

trait t_area {
    fn area(this) -> f64;
}

trait t_name {
    fn name(this) -> str;
}

<T: type>
trait t_source {
    fn next(this) -> T?;
}

struct circle { r: f64; }
struct square { side: f64; }

attach t_area -> circle {
    fn area(this) -> f64 { return 3.0 * this.r * this.r; }
}

attach t_area -> square {
    fn area(this) -> f64 { return this.side * this.side; }
}

attach t_name -> square {
    fn name(this) -> str { return "square"; }
}

attach t_source<i32> -> circle {
    fn next(this) -> i32? { return null; }
}

<T: type>
fn describe(s: T&) -> void {
    comptime if (@attaches(T, t_name)) {
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
    std::println("{} {} {}", @attaches(circle, t_area), @attaches(circle, t_name), @attaches(i32, t_area));
    std::println("{} {}", @attaches(circle, t_source<i32>), @attaches(circle, t_source<i64>));
}
// expect: something: 3
// expect: square: 4
// expect: true false false
// expect: true false
