use std::io;

// templates, like C++: one copy per type, checked when instantiated
<T: type>
fn largest(xs: T[..]) -> T {
    var best = xs[0];
    for (x) in xs {
        if (x > best) {
            best = x;
        }
    }
    return best;
}

// traits are constraints; as a type, a tagged union of every type
// that attaches them. No vtables, no heap
trait t_shape {
    fn area(this) -> f64;
}

struct circle { r: f64; }
struct square { side: f64; }

attach t_shape -> circle {
    fn area(this) -> f64 { return 3.14159 * this.r * this.r; }
}

attach t_shape -> square {
    fn area(this) -> f64 { return this.side * this.side; }
}

fn main() -> void {
    val xs: i32[] = { 3, 9, 4 };
    std::println("{}", largest(xs[..]));
    val c: circle = { r: 1.0 };
    val q: square = { side: 2.0 };
    val shapes: t_shape[] = { c, q };
    for (s&) in shapes {
        std::println("{}", s.area());
    }
}
// expect: 9
// expect: 3.14159
// expect: 4
