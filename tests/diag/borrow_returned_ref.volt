// the borrow warnings: returning a local that holds a reference to one of the function's own locals
// (in a struct, given later through a field, or a pointer) warns, and the program still builds; a
// reference the caller gave, or a value read through one, doesn't
use std::io;
struct view { x: i32&; }
fn make() -> view {
    var n = 5;
    val v: view = { x: &n };
    return v;
}
fn later() -> view {
    var n = 6;
    var v: view = { x: &n };
    var m = 7;
    v.x = &m;
    return v;
}
fn pointer() -> i32* {
    var n = 1;
    val r: i32* = &n;
    return r;
}
fn fine(out: i32&) -> view {
    val v: view = { x: out };
    return v;
}
fn fine2() -> i32 {
    var n = 5;
    val r = &n;
    return *r;
}
fn main() -> void {
    var k = 3;
    std::println(*fine(&k).x + fine2());
    std::println(*make().x + *later().x + *pointer());
}
