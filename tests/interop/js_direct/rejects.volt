use std::io;
// an async function's rejection stops the program with its text, as a throw does
use { "geom.ts" } as geom;

fn main() -> void {
    std::println("{}", geom::rejectLater("no"));
}
