use std::io;
// a thrown exception stops the program, with its text
use { "geom.ts" } as geom;

fn main() -> void {
    std::println("{}", geom::fail("boom"));
}
