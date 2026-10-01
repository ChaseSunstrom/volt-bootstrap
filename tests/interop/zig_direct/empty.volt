use std::io;
// an empty handle (Zig never made it): using it stops the program
use zig { "fastmath.zig" } as fm;

fn main() -> void {
    var s: fm::shapes::Shape = {};
    std::println("{}", s.perimeter());
}
