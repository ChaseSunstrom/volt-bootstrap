use std::io;
// a Rust panic through a plain call stops the program with Rust's message (exit code 101)
use { "geom" } as geom;

fn main() -> void {
    val xs: i32[2] = { 1, 2 };
    std::println("{}", geom::at(xs[..], 3));
}
