// op::box<int> (ibox) has no default constructor: {} can't make one
use { "opaque.hpp" } as cpp;

fn main() -> void {
    val b: cpp::op::ibox = {};
}
