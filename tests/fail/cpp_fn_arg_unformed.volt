// a plain fn whose result has no C form has no C function pointer for a C++ template either
use std::string;
use { "cpp_fn_arg_closure.hpp" } as cpp;
fn name() -> std::string {
    return std::string::from("x");
}
fn main() -> void {
    val n = cpp::apply(name);
}
// error: has no C++ spelling: it returns a std::string
// error: which has no C function-pointer form
