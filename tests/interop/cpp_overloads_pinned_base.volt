// an && method of a class that can be neither copied nor moved, through a borrowed handle (as_Base):
// there's no object to hand C++ (no copy), so the call stops the program before it reads the object
use std::io;
use { "overloads.hpp" } as cpp;
fn main() -> void {
    val c = cpp::ov::PinnedCrate::new(8);
    std::println("before {}", c.as_Pinned().peek());
    std::println("taken {}", c.as_Pinned().take());
}
