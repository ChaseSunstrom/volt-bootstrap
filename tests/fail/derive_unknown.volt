// @derive names traits: one that's neither in scope nor std::derive's is an error
@attributes([@derive(eq, sortable)])
struct point {
    x: i32;
}

fn main() -> void {}
// error: unknown trait 'sortable'
