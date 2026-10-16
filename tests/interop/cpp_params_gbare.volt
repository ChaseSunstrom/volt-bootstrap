// a template's S& and const S& take a Volt reference: a std::string passed without & (which would
// move it into the call) is an error naming the parameter
use std::io;
use { "params.hpp" } as cpp;
fn main() -> void {
    var t = std::string::from("a");
    cpp::pr::gs::wrap(t);
    std::println("{}", t);
}
fn read(t: std::string) -> u64 {
    return cpp::pr::gs::len(t);
}
