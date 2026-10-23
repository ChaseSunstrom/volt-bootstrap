// a call worked out per use with an int& and an int* parameter takes each Volt reference as its
// parameter wants it; f(T&) beside f(T*) still gets f(&x) as f(T&)
use std::io;
use { "cpp_ref_mix.hpp" } as cpp;

fn main() -> void {
    var a: i32 = 1;
    var b: i32 = 2;
    cpp::rm::mix(&a, &b);
    std::println("mix {} {}", a, b);
    var x: f64 = 1.0;
    var y: f64 = 2.0;
    cpp::rm::mix(&x, &y);
    std::println("mix {} {}", x, y);
    cpp::rm::swap_in(&a, &b);
    std::println("swap {} {}", a, b);
    std::println("pick {} {}", cpp::rm::pick(&a), cpp::rm::pick(&x));
}
