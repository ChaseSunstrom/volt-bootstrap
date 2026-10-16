// a call worked out per use reads every Volt reference one way: as an lvalue, or else as its
// address; one argument as each isn't taken, and the error is the lvalue reading's
use std::io;
use { "params.hpp" } as cpp;
fn main() -> void {
    var a: i32 = 1;
    var b: i32 = 2;
    std::println("{}", cpp::pr::rp::mixed(&a, &b));
}
