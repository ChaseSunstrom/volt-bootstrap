// an explicit template argument naming a Volt struct, a tuple or an enum with payloads in a call
// made per use: C++ gets its mirror, as for a deduced one
use std::io;
use { "cpp_peruse3.hpp" } as cpp;

struct point { x: i32; y: f64; }

// (no padding: C++ compares the bytes)
struct cell { x: i32; y: i32; }

enum shape { DOT, LINE: i32, BOX: f64 }

struct rect { w: i32; h: i32; }

struct seg { a: cell; b: cell; }

struct node { next: node*; v: i32; }

fn main() -> void {
    val a: cell = { x: 3, y: 4 };
    val b: cell = { x: 3, y: 5 };
    std::println("struct {} {}", cpp::pu3::same<cell>(a, a), cpp::pu3::same<cell>(a, b));
    val t: (i32, i32) = (4, 6);
    val u: (i32, i32) = (4, 7);
    std::println("tuple {} {}", cpp::pu3::same<(i32, i32)>(t, t), cpp::pu3::same<(i32, i32)>(t, u));
    std::println("size {} {} {}", cpp::pu3::size_of<point>() == @sizeof(point), cpp::pu3::size_of<shape>() == @sizeof(shape), cpp::pu3::size_of<(i32, f64)>() == @sizeof((i32, f64)));
    // a struct's and a tuple's fields, read by a template
    val r: rect = { w: 3, h: 4 };
    val sg: seg = { a: { x: 1, y: 2 }, b: { x: 7, y: 9 } };
    val r2 = cpp::pu3::bump(r);
    var n2: node = { next: null, v: 8 };
    val n1: node = { next: &n2, v: 1 };
    std::println("fields {} {} {} {} {}", cpp::pu3::area(r), cpp::pu3::span_x(sg), cpp::pu3::sum2(t), r2.w, cpp::pu3::second(n1));
}
// expect: struct true false
// expect: tuple true false
// expect: size true true true
// expect: fields 12 6 10 4 8
