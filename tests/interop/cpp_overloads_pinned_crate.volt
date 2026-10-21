// an && method a class that can be neither copied nor moved inherits (worked out per use), through
// a borrowed handle (a reference result): no object to hand C++, so the call stops the program
use std::io;
use { "overloads.hpp" } as cpp;
fn main() -> void {
    std::println("before {}", cpp::ov::crate_shelf().peek());
    std::println("taken {}", cpp::ov::crate_shelf().take());
}
