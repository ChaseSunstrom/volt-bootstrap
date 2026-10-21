// an explicit template argument naming a Volt struct, a tuple or an enum with payloads in a call
// made per use: C++ gets its mirror, as for a deduced one
use std::io;
use { "cpp_peruse3.hpp" } as cpp;

struct point { x: i32; y: f64; }

// (no padding: C++ compares the bytes)
struct cell { x: i32; y: i32; }

enum shape { DOT, LINE: i32, BOX: f64 }

fn main() -> void {
    val a: cell = { x: 3, y: 4 };
    val b: cell = { x: 3, y: 5 };
    std::println("struct {} {}", cpp::pu3::same<cell>(a, a), cpp::pu3::same<cell>(a, b));
    val t: (i32, i32) = (4, 6);
    val u: (i32, i32) = (4, 7);
    std::println("tuple {} {}", cpp::pu3::same<(i32, i32)>(t, t), cpp::pu3::same<(i32, i32)>(t, u));
    std::println("size {} {} {}", cpp::pu3::size_of<point>() == @sizeof(point), cpp::pu3::size_of<shape>() == @sizeof(shape), cpp::pu3::size_of<(i32, f64)>() == @sizeof((i32, f64)));
}
// expect: struct true false
// expect: tuple true false
// expect: size true true true
