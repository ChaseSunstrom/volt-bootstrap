use std::io;
// a lent handle (a reference into Rust's tree) can't be given away: the program stops
use { "geom" } as geom;

fn main() -> void {
    var t = geom::Tree::new(2);
    var n = t.first_mut();
    std::println("{}", n.boxed_value());
}
