// glm, as installed: its generic functions over plain numbers (its vectors take a length as a
// template value, which Volt's generics can't)
use std::io;
use { "glm/glm.hpp" } as cpp;

fn main() -> void {
    std::println("{} {} {}", cpp::glm::abs(-2.5), cpp::glm::min(3, 7), cpp::glm::clamp(1.5, 0.0, 1.0));
}
