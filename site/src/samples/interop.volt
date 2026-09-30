use std::io;
use cpp { "geometry.hpp" } as cpp;   // C++ headers, read by libclang
use { "math.h" } as c;               // C headers too

fn main() -> void {
    var path = cpp::geo::Path::new();  // a constructor
    path.add({ x: 0.0, y: 0.0 });      // methods, C++ layouts
    path.add({ x: 3.0, y: 4.0 });
    val len = path.length();
    val top = cpp::geo::clamp<i32>(12, 0, 10);  // a function template
    std::println("{} {} {}", len, top, c::floor(2.7));
}
// expect: 5 10 2
