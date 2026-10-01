use std::io;
// an empty handle (never made by Rust, or given to it already): using it stops the program
use rust { "geom" } as geom;

fn main() -> void {
    var s: geom::shapes::Shape = {};
    std::println("{}", s.perimeter());
}
