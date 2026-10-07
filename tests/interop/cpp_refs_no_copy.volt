// rf::Shelf holds a std::vector<std::unique_ptr<Widget>>: C++ says it can be copied, but its copy
// doesn't compile, so it has no copy
use { "refs.hpp" } as cpp;

fn main() -> void {
    val s: cpp::rf::Shelf = {};
    val s2 = copy s;
}
