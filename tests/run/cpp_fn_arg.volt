// a plain Volt fn passed where a C++ template deduces its parameter's type: it crosses as its C
// function pointer
use std::io;
use { "cpp_fn_arg.hpp" } as cpp;

fn seven() -> i32 {
    return 7;
}

fn twice(x: i32) -> i32 {
    return x * 2;
}

fn main() -> void {
    std::println("{} {}", cpp::apply(seven), cpp::apply1(twice, 4));
    std::println("{} {}", cpp::pick(seven), cpp::pick(twice));
}
// expect: 7 8
// expect: 7 102
