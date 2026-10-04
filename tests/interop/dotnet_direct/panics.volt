use std::io;
// an exception stops the program, with its text
use { "Geo.cs" } as geo;

fn main() -> void {
    std::println("{}", geo::Geom::Divide(1, 0));
}
