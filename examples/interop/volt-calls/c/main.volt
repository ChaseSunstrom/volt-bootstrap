// Volt calling C: the use reads shapes.h, so rect is a Volt struct and its functions are Volt
// functions; shapes.c is compiled along with the program. Run: sh run.sh
use std::io;
use { "shapes.h" } as c;

fn main() -> void {
    var r: c::rect = { w: 3.0, h: 4.0 };
    std::println("area {}", c::rect_area(r));
    c::rect_scale(&r, 2.0);
    std::println("scaled {} {}", r.w, r.h);
    std::println("{}", c::shape_name(4));
}
