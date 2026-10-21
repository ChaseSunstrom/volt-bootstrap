// a capturing closure has no C function pointer: a C++ template's deduced parameter takes a plain
// fn's name only
use { "cpp_fn_arg_closure.hpp" } as cpp;
fn main() -> void {
    val k = 3;
    val add = |k| (x: i32) -> i32 { return x + k; };
    val n = cpp::apply1(add, 4);
}
// error: closure(i32) -> i32 has no C++ spelling: a closure has no C++ form; pass a plain fn's name
