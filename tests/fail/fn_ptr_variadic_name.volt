// A C variadic fn's type, named in an error, has its ...
extern "C" fn snprintf(buf: u8*, n: usize, fmt: cstr, ...) -> i32;
fn main() -> void {
    val f: extern "C" fn(u8*, usize, cstr) -> i32 = snprintf;
}
// error: extern "C" fn(u8*, usize, cstr, ...) -> i32
