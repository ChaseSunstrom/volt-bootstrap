// a Volt struct owning memory (a std::string field) isn't handed to C++ as its bytes: C++ would copy
// what it owns
use std::string;
use { "cpp_fn_arg_closure.hpp" } as cpp;
struct named { s: std::string; }
fn main() -> void {
    val n: named = { s: std::string::from("x") };
    val m = cpp::echo(n);
}
// error: named has no C++ spelling: it has a delete, and C++ would copy what it owns
// error: echo<named> is instantiated here
