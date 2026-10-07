// tests/run/c_macros.h under C99, a standard other than Volt's own C's: its per-use calls' C
// functions go in that standard's unit, and Volt calls them through its pointers there, as it does
// the header's own functions
use std::io;
@attributes([@standard("c99")])
use { "c_macros.h" } as m;

fn main() -> void {
    val a: i32 = 3;
    val x: f64 = 2.5;
    std::println("{} {} {}", m::MAX(a, 9), m::SQUARE(x), m::vsum(2, 20, 22));
    std::println("{} {}", m::ldsum(3, 0.5, 0.25, 0.25), m::cmake(1, 4.0).re);
}
// expect: 9 6.25 42
// expect: 1 4
