// C before C23 has no variadic function without a fixed parameter: a declaration of one is refused
extern "C" fn printf(...) -> i32;
fn main() -> void {
    printf();
}
// error: c_variadic_no_fixed_decl.volt:2
// error: a C variadic function needs a fixed parameter before its ...
