use std::io;
// an exception a Java method doesn't declare stops the program, with its text
use { "geo/Geom.java" } as geo;

fn main() -> void {
    std::println("{}", geo::Geom::divide(1, 0));
}
