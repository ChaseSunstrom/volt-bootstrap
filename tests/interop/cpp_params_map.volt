// a mutable std::map& with no handle form has no Volt form (C++ would change a copy): its function
// stays per use, and a call with a Volt map names the type
use std::io;
use { "params.hpp" } as cpp;
fn main() -> void {
    var m: std::map<std::string, i32> = {};
    std::println("{}", cpp::pr::mp::put_s(&m));
}
