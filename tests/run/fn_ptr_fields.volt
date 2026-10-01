use std::io;
// a struct holding optional function pointers and fn values that take the struct itself (the
// C backend defines the pointer typedefs before the struct's body)

struct node {
    n: i32 = 0;
    cb: (extern "C" fn(node) -> node)? = null;
    each: (fn(node, i32[..]) -> i32)? = null;
}

extern "C" fn bump(x: node) -> node {
    return { n: x.n + 1 };
}

fn main() -> void {
    var a: node = { n: 1, cb: bump };
    a.each = || (x: node, xs: i32[..]) -> i32 { return x.n + @cast<i32>(xs.len); };
    val f = a.cb ?? return;
    val g = a.each ?? return;
    val xs: i32[3] = { 1, 2, 3 };
    std::println("{} {}", f(a).n, g(a, xs[..]));
}
// expect: 2 4
