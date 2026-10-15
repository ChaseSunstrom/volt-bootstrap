// a parameter with no Volt form (a nested std::vector of bools) leaves its function per use: its
// stub says why, and a call with a value C++ can't take names the type
use std::io;
use { "params.hpp" } as cpp;
fn main() -> void {
    std::println("{}", cpp::pr::nv::flags(3));
}
