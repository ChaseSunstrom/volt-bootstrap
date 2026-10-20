use std::io;
// an async function whose promise never settles (there's no event loop to wait on) stops the program
use { "geom.ts" } as geom;

fn main() -> void {
    std::println("{}", geom::never());
}
