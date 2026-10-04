// a comptime global's declared type guides its value: a struct literal is that struct (defaults filled)
use std::io;
struct point { x: i32; y: i32 = 5; }
comptime val P: point = { x: 1, y: 2 };
val Q: point = { x: 3 };
fn main() -> void {
    std::println("{} {} {}", P.x, Q.y, P.y);
    comptime val r = P;
    std::println("{}", r.x);
}
// expect: 1 5 2
// expect: 1
