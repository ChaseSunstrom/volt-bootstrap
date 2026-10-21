// a closure taking text has no std::function form for a C++ template
use { "cpp_fn_arg_closure.hpp" } as cpp;
fn main() -> void {
    val k = 1;
    val f = |k| (s: str) -> i32 { return k; };
    val n = cpp::apply1(f, 2);
}
// error: a closure is a std::function only of numbers, bools, pointers and enums
