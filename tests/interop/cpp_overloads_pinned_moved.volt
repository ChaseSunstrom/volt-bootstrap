// an && method of a class that can be neither copied nor moved consumes the handle too: using it
// afterwards is a use after move
use std::io;
use { "overloads.hpp" } as cpp;
fn main() -> void {
    val p = cpp::ov::Pinned::new(3);
    std::println("{}", p.take());
    std::println("{}", p.peek());
}
