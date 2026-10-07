// A C++20 named module (geomod.cppm, which imports std; imported twice, built once) and a header
// that does `import std;`: each imports as a header does, a module with what it exports
use std::io;
use { "geomod.cppm" } as gm;
use { "geomod.cppm" } as gm2;
use { "uses_std.hpp" } as us;

fn main() -> void {
    var c = gm::geo::Counter::new(5);
    c.bump();
    std::println("{} {} {} {}", gm::geo::twice(21), gm::geo::label(7), gm::geo::triple(4), c.value());
    val v: i32[3] = { 1, 2, 3 };
    std::println("{} {} {}", us::us::total(v[0..3]), us::us::greet("volt"), gm2::geo::twice(4));
}
