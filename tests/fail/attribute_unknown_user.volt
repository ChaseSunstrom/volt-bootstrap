// a library attribute is evaluated when @typeinfo reads it: one naming nothing is an error then
use std::io;

struct point {
    @attributes([ser::nope("x")])
    x: i32;
}

fn main() -> void {
    comptime match (@typeinfo(point).kind) {
        .STRUCT(s) => {
            comptime for (f) in s.0 {
                std::println("{}", f.name);
            }
        },
        default => {},
    }
}
// error: no function 'nope' to call at compile time
