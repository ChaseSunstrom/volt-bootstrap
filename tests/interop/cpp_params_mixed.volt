// a call worked out per use with an int& and an int* parameter takes each Volt reference as its
// parameter wants it; when no reading fits (an f64 for the int*), the error is the lvalue reading's
use std::io;
use { "params.hpp" } as cpp;
fn main() -> void {
    var a: i32 = 1;
    var b: f64 = 2.0;
    std::println("{}", cpp::pr::rp::mixed(&a, &b));
}
