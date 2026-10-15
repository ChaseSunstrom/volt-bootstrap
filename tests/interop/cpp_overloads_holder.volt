// an && method of a class template held by handle is worked out per use, where the object is an
// lvalue: C++'s error, never a move out of an object the handle may only borrow
use std::io;
use { "overloads.hpp" } as cpp;
fn main() -> void {
    val h = cpp::ov::Holder<i32>::new(5);
    std::println("{}", h.take());
}
