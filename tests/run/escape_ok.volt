// What a function may return by reference: what its caller lent it, never its own locals
use std::io;

struct point {
    x: i32;
}

attach fn x_of(this: point&) -> i32& {
    return &this.x;
}

fn first(xs: i32[..]) -> i32& {
    return &xs[0];
}

fn pick(p: point&) -> i32& {
    return &p.x;
}

fn same(r: i32&) -> i32& {
    return r;
}

fn twice(n: i32) -> i32 {
    return n * 2;
}

// a plain function is a fn value of its own: no closure to lose
fn get() -> fn(i32) -> i32 {
    return twice;
}

fn main() -> void {
    var p: point = { x: 1 };
    *p.x_of() += 1;
    *pick(&p) += 1;
    var a: i32[2] = { 5, 6 };
    *first(a[..]) += 1;
    std::println("{} {} {} {}", p.x, a[0], *same(&p.x), get()(21));
}
// expect: 3 6 3 42
