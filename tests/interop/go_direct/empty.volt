use std::io;
// an empty handle (Go never made it): using it stops the program
use { "geom.go" } as geom;

fn main() -> void {
    var s: geom::Shape = {};
    std::println("{}", s.Perimeter());
}
