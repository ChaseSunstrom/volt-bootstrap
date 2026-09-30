use std::io;
// a C++ exception reaching Volt stops the program with its message
use cpp { "shapes.hpp" } as shapes;

fn main() -> void {
    val s = shapes::geo::Shape::new(1, 1);
    std::println("{}", s.checked(-1));
}
