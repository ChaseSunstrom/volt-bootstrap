use std::io;

struct rect {
    w: f64;
    h: f64;
}

fn area(r: rect) -> f64 {
    return r.w * r.h;
}

fn main() -> void {
    val r: rect = { w: 3.0, h: 4.5 };
    std::println("area {}", area(r));
}
// expect: area 13.5
