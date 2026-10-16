// glm, as installed: its generic functions over plain numbers, and its vectors by their template
// (vec<L, T, Q>, declared only: a generic handle <L: i32, T>, Q left to C++'s default)
use std::io;
use { "glm/glm.hpp" } as cpp;

fn main() -> void {
    std::println("{} {} {}", cpp::glm::abs(-2.5), cpp::glm::min(3, 7), cpp::glm::clamp(1.5, 0.0, 1.0));
    val v = cpp::glm::vec<3, f32>::new(1.0, 2.0, 2.0);
    std::println("length {}", cpp::glm::length(&v));
}
