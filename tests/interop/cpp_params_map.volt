// a mutable std::map& with no stdcxx form takes a Volt map too (beside the handle of its own): C++
// changes a copy, whose entries the Volt map gets back once the call returns
use std::io;
use { "params.hpp" } as cpp;
fn main() -> void {
    var m: std::map<std::string, i32> = {};
    std::println("{} {}", cpp::pr::mp::put_s(&m), *(m.get(std::string::from("z")) ?? return));
}
