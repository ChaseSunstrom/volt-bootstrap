// an explicit template argument naming a Volt struct, a tuple or an enum with payloads in a per-use
// call: C++ gets its mirror, as for a deduced one
use std::io;
use { "cpp_peruse3.hpp" } as cpp;

struct point { x: i32; y: f64; }

enum shape { DOT, LINE: i32, BOX: f64 }

fn main() -> void {
    val p: point = { x: 3, y: 2.5 };
    val q = cpp::pu3::echo<point>(p);
    std::println("struct {} {}", q.x, q.y);
    val t: (i32, f64) = (4, 0.5);
    std::println("tuple {}", cpp::pu3::echo<(i32, f64)>(t));
    match (cpp::pu3::echo<shape>(shape::BOX(1.25))) {
        .BOX(v) => { std::println("enum {}", v); },
        default => { std::println("enum ?"); },
    }
    std::println("size {} {}", cpp::pu3::size_of<point>() == @sizeof(point), cpp::pu3::size_of<shape>() == @sizeof(shape));
}
// expect: struct 3 2.5
// expect: tuple (4, 0.5)
// expect: enum 1.25
// expect: size true true
