use std::io;
// a type a generic Rust fn's bounds reject (Counter isn't Clone): rustc's reason is the error, at
// the call
use { "geom" } as geom;

fn main() -> void {
    val k = geom::shapes::Counter::new();
    val d = geom::dup(&k);
}
