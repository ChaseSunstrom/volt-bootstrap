use std::io;
// a method named like a namespace doesn't hide it: a path through `shapes::` means the namespace,
// and b.shapes() the method
namespace shapes {
    fn area(w: i32, h: i32) -> i32 {
        return w * h;
    }
}

struct rect {
    w: i32;
    h: i32;
}

attach fn shapes(this: rect&) -> i32 {
    return shapes::area(this.w, this.h);
}

fn main() -> void {
    val r: rect = { w: 2, h: 3 };
    std::println("{} {}", r.shapes(), shapes::area(4, 5));
}
// expect: 6 20
