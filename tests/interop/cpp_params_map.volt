// a mutable std::map& with no stdcxx form takes only the handle of its own (C++ would change a copy
// of a Volt map): a call with a Volt map is refused, naming both types
use std::io;
use { "params.hpp" } as cpp;
fn main() -> void {
    var m: std::map<std::string, i32> = {};
    std::println("{}", cpp::pr::mp::put_s(&m));
}
