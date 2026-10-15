// a static fn of a trait, called through a trait union value: the held member's static fn runs
// (the receiver is evaluated once, only its tag is read)
use std::io;

trait shape {
    fn area(this) -> f64;
    fn kind_name(static this) -> str;
    @attributes([@optional])
    fn sides(static this) -> i32;
}

struct circle { r: f64; }
struct square { side: f64; }
struct blob { n: i32; }

attach shape -> circle {
    fn area(this) -> f64 { return 3.0 * this.r * this.r; }
    fn kind_name(static this) -> str { return "circle"; }
    fn sides(static this) -> i32 { return 0; }
}

attach shape -> square {
    fn area(this) -> f64 { return this.side * this.side; }
    fn kind_name(static this) -> str { return "square"; }
    fn sides(static this) -> i32 { return 4; }
}

// blob leaves sides out: the blanket fn below serves it
attach shape -> blob {
    fn area(this) -> f64 { return 0.0; }
    fn kind_name(static this) -> str { return "blob"; }
}

<T: shape>
attach fn sides(static this: T) -> i32 { return -1; }

var made = 0;

fn make(i: i32) -> shape {
    made += 1;
    if (i == 0) {
        val c: circle = { r: 1.0 };
        return c;
    }
    val q: square = { side: 2.0 };
    return q;
}

fn name_of(s: shape&) -> str {
    return s.kind_name();
}

fn main() -> void {
    val c: circle = { r: 1.0 };
    val q: square = { side: 2.0 };
    val b: blob = { n: 1 };
    val shapes: shape[] = { c, q, b };
    for (s&) in shapes {
        std::println("{} {}", s.kind_name(), s.sides());
    }
    val first = shapes[0];
    std::println(first.kind_name());
    std::println(name_of(&shapes[1]));
    std::println(make(1).kind_name());
    std::println(made);
    std::println(make(0).sides());
    std::println(made);
}
// expect: circle 0
// expect: square 4
// expect: blob -1
// expect: circle
// expect: square
// expect: square
// expect: 1
// expect: 0
// expect: 2
