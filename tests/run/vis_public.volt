// flags: --pkg vis=tests/pkgs/vis
use std::io;
// another package's public items: its fns, globals, structs (fields and all), public methods, traits
// and the functions of its attach blocks, and its export fns

struct circle { r: i32; }

attach vis::shape -> circle {
    fn area(this) -> i32 { return 3 * this.r * this.r; }
}

<T: vis::shape>
fn area_of(s: T) -> i32 {
    return s.area();
}

fn main() -> void {
    val p: vis::point = { x: 1, y: 2 };
    val sq: vis::square = { side: 4 };
    val c: circle = { r: 1 };
    std::println("{} {} {} {}", vis::answer(), vis::LIMIT, p.sum(), p.x);
    std::println("{} {} {}", area_of(sq), area_of(c), vis::vis_seven());
}
// expect: 42 3 3 1
// expect: 16 3 7
