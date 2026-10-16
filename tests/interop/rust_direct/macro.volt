use std::io;
// with rustdoc unable to write its JSON, bolt reads rustc's expanded source: what macros make is there
use { "geom" } as geom;

fn main() -> void {
    std::println("macro {} {}", geom::answer(), geom::made_by_macro());
}
// expect: macro 42 7
