// a field takes a library's attributes; the builtins are about declarations
struct point {
    @attributes([@inline])
    x: i32;
}

fn main() -> void {}
// error: @inline goes on a declaration, not a field
