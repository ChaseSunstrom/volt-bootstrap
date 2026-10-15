// an && method of a class template held by handle, worked out per use, consumes the handle as a
// declared one does: using it afterwards is a use after move
use std::io;
use { "overloads.hpp" } as cpp;
fn main() -> void {
    val h = cpp::ov::Holder<i32>::new(5);
    std::println("{}", h.take());
    std::println("{}", h.peek());
}
