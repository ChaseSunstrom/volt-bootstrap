// a comptime for in a type body binds a name for each item (and maybe one for its index)
comptime fn empty(T: type) -> type {
    return struct {
        comptime for () in @typeinfo(T).fields {
            x: i32;
        }
    };
}

fn main() -> void {}
// error: a comptime for in a type body binds one or two names: (x) or (x, i)
