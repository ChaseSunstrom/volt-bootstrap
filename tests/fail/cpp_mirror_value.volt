// a Volt struct in @cpp text goes by its address: C++ has it as its bytes, so a value is refused
use { "cpp_fn_arg_closure.hpp" } as cpp;
struct point { x: i32; y: f64; }
fn main() -> void {
    val p: point = { x: 1, y: 2.0 };
    val n = @cpp<i32>("int(sizeof({0}))", p);
}
// error: pass point by reference (&x): C++ has it as its bytes
