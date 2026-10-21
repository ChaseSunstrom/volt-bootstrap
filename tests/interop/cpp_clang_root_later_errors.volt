// per-use @cpps from the program's own code with two imports, neither making the call: the error
// is the one of the import that has the name (the second: grow takes no cstr), not the first's
// "undeclared identifier"; a name no import has is the first's
use std::io;

fn wrong() -> i32 {
    var t = std::string::from("ab");
    return @cpp<i32, std::string>("pr::gs::grow<{t0}>({0}, {1})", t, "x");
}

fn nowhere() -> i32 {
    return @cpp("nowhere::f({0})", 1);
}

use { "cpp_twin.hpp" } as tw;
use { "params.hpp" } as cpp;

fn main() -> void {
    std::println("{} {}", wrong(), nowhere());
}
