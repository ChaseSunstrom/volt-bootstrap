// below C++17 (run with --cc -std=c++14): a class held by handle (not trivially copyable) aligned to
// 32 can't be made by plain new: its build fails naming C++17's aligned new (T-0645)
use std::io;
use { "cpp_aligned_field.hpp" } as cpp;

fn main() -> void {
    var nb: cpp::af::nbig = {};
    std::println("big {}", nb.size());
}
