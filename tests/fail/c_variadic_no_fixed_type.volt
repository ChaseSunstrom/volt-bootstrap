// C before C23 has no variadic function without a fixed parameter: a function pointer type of one is
// refused where it's written
fn main() -> void {
    val f: extern "C" fn(...) -> i32 = null;
}
// error: c_variadic_no_fixed_type.volt:4
// error: a C variadic function needs a fixed parameter before its ...
