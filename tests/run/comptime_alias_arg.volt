// a type alias is a type at compile time too: an argument to a comptime fn, or a value in comptime
// code, like the type it names
use std::io;

type int_ref = i32&;
type floats = f64[..];
type id = u64;

comptime fn pointee(T: type) -> str {
    match (@typeinfo(T).kind) {
        .REFERENCE(t) | .POINTER(t) | .SLICE(t) => { return @typeinfo(t).short_name; },
        default => { return @typeinfo(T).short_name; },
    }
}

fn main() -> void {
    comptime val same = id == u64;
    std::println("{} {} {} {}", pointee(int_ref), pointee(floats), pointee(id), same);
}
// expect: i32 f64 u64 true
