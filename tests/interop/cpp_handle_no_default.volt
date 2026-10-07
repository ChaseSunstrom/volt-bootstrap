// h::only has no default constructor, so {} can't make one
use { "handles_default.hpp" } as cpp;

fn main() -> void {
    val b: cpp::h::only = {};
}
