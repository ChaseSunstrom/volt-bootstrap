// a Volt struct owning memory (a std::string field) named as an explicit template argument of a call
// made per use has no mirror: C++ would copy what it owns
use std::string;
use { "cpp_explicit_owned.hpp" } as cpp;
struct named { s: std::string; }
fn main() -> void {
    val n = cpp::size_of<named>();
}
// error: named has no C++ spelling: it has a delete, and C++ would copy what it owns
