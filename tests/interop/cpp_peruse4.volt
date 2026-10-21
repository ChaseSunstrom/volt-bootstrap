// a call made per use whose result is a Volt struct, a tuple or an enum with payloads (C++'s mirror
// of it), deduced or with the template argument given, or named only in the result: that Volt value
use std::io;
use { "cpp_peruse4.hpp" } as cpp;

struct point { x: i32; y: f64; }

enum shape { DOT, LINE: i32, BOX: f64 }

fn size(s: shape) -> f64 {
    match (s) {
        .DOT => { return 0.0; },
        .LINE(n) => { return @cast<f64>(n); },
        .BOX(v) => { return v; },
    }
}

fn main() -> void {
    val p: point = { x: 3, y: 2.5 };
    val a = cpp::pu4::echo(p);
    val b = cpp::pu4::echo<point>(p);
    std::println("struct {} {} {} {}", a.x, a.y, b.x, b.y);
    val t: (i32, f64) = (4, 0.5);
    std::println("tuple {} {}", cpp::pu4::echo(t), cpp::pu4::echo<(i32, f64)>(t));
    std::println("enum {} {}", size(cpp::pu4::echo(shape::BOX(1.25))), size(cpp::pu4::echo<shape>(shape::LINE(7))));
    val z = cpp::pu4::zero<point>();
    std::println("zero {} {} {} {}", z.x, z.y, cpp::pu4::zero<(i32, f64)>(), size(cpp::pu4::zero<shape>()));
    // its try_ form, whose call of the plain one binds the mirror the same way
    val tz = cpp::pu4::try_zero<point>() catch p;
    std::println("try {}", tz.x);
    var g = cpp::pu4::global<point>();
    g.x = 9;
    std::println("conv {} global {} {}", size(cpp::pu4::conv<point, shape>(p)), g.x, cpp::pu4::global<point>().x);
    var m: point = { x: 5, y: 1.5 };
    val q = cpp::pu4::addr(&m);
    q->x = 6;
    val w = cpp::pu4::nowhere<point>();
    std::println("addr {} {} {}", m.x, q->y, w == null);
}
// expect: struct 3 2.5 3 2.5
// expect: tuple (4, 0.5) (4, 0.5)
// expect: enum 1.25 7
// expect: zero 0 0 (0, 0) 0
// expect: try 0
// expect: conv 0 global 9 0
// expect: addr 6 1.5 true
