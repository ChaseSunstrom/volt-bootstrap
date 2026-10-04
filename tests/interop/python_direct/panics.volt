use std::io;
// a Python exception stops the program, with its type and message
use { "geom.py" } as geom;

fn main() -> void {
    std::println("{}", geom::divide(1, 0));
}
