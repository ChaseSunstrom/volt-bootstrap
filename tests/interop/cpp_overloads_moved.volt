// an && method consumes the handle: using it afterwards is a use after move
use std::io;
use { "overloads.hpp" } as cpp;
fn main() -> void {
    val bx = cpp::ov::Box::new(7);
    val s = bx.open_rref();
    std::println("{} {}", s, bx.peek());
}
