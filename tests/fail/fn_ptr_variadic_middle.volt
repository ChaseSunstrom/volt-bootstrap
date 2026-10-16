// A C variadic function pointer type's ... is its last parameter
fn main() -> void {
    val f: extern "C" fn(i32, ..., i32) -> i32 = null;
}
// error: fn_ptr_variadic_middle.volt:3
// error: expected ')'
