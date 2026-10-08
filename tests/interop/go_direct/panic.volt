use std::io;
// a Go panic through a plain call stops the program with Go's message
use { "geom.go" } as geom;

fn main() -> void {
    val xs: isize[2] = { 1, 2 };
    std::println("{}", geom::At(xs[..], 3));
}
