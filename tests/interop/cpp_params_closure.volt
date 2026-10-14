// a function pointer parameter takes an extern "C" fn: a closure (it has an environment) is an error
use std::io;
use { "params.hpp" } as cpp;
fn main() -> void {
    val k = 2;
    std::println("{}", cpp::pr::apply(|k| (x: i32) -> i32 { return x + k; }, 1));
}
