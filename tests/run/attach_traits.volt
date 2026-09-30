use std::io;

struct counter { n: i32; }

attach fn new(static this: counter, start: i32) -> counter {
    return { n: start };
}

attach fn bump(this: counter&) -> void {
    this.n += 1;
}

attach fn get(this: counter) -> i32 {
    return this.n;
}

// blanket attach: every type gets describe()
<T: type>
attach fn describe(this: T) -> str {
    return "a value";
}

trait t_shape {
    fn area(this) -> f64;
    fn name(this) -> str;
}

struct circle { r: f64; }
struct square { side: f64; }

attach t_shape -> circle {
    fn area(this) -> f64 { return 3.0 * this.r * this.r; }
    fn name(this) -> str { return "circle"; }
}

attach t_shape -> square {
    fn area(this) -> f64 { return this.side * this.side; }
    fn name(this) -> str { return "square"; }
}

<T: t_shape>
fn print_shape(s: T&) -> void {
    std::println("{}: {}", s.name(), s.area());
}

fn main() -> void {
    var c = counter::new(40);
    c.bump();
    c.bump();
    std::println("{} {}", c.get(), c.describe());
    val ci: circle = { r: 1.0 };
    val sq: square = { side: 3.0 };
    print_shape(&ci);
    var list: t_shape[] = { ci, sq };
    for (s&) in list {
        print_shape(s);
    }
    std::println(list[1]);
    match (list[0]) {
        circle(x) => std::println("r = {}", x.r),
        square(x) => std::println("side = {}", x.side),
    }
    std::println(@sizeof(t_shape) >= @sizeof(circle));
}
// expect: 42 a value
// expect: circle: 3
// expect: circle: 3
// expect: square: 9
// expect: square { side: 3 }
// expect: r = 1
// expect: true
