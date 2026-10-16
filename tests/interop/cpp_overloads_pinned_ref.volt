// a const && method of a class that can be neither copied nor moved, through a borrowed handle (a
// reference result): the call stops the program, naming the overload
use std::io;
use { "overloads.hpp" } as cpp;
fn main() -> void {
    std::println("before {}", cpp::ov::pinned_shelf().peek());
    std::println("taken {}", cpp::ov::pinned_shelf().take_const_rref());
}
