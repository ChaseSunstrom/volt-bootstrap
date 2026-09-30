use std::io;
// an optional of an optional: the outer one says whether there is a value at all
fn first(v: cstr?[..]) -> cstr?? {
    if (v.len == 0) { return null; }
    return v[0];
}
fn main() -> void {
    val xs: cstr?[] = { null, "b" };
    val a = first(xs[..]);
    val b = first(xs[1..2]);
    val none: cstr?[] = {};
    std::println("{} {} {}", a, b, first(none[..]));
}
// expect: null b null
