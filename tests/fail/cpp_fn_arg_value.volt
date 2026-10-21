// a fn value held in a local isn't a plain fn's name: it has no C function pointer to give C++
use { "cpp_fn_arg_closure.hpp" } as cpp;
fn twice(x: i32) -> i32 {
    return x * 2;
}
fn main() -> void {
    val g = twice;
    val n = cpp::apply1(g, 4);
}
// error: fn(i32) -> i32 has no C++ spelling: a fn value has no C++ form; pass a plain fn's name
