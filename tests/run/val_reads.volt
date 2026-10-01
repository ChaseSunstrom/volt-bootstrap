use std::io;
// reading through references to vals is fine: methods that only read, functions that only read
// (even recursively, or by passing the reference on), and copies
struct point {
    x: i32;
    y: i32;
}

attach fn sum(this: point&) -> i32 {
    return this.x + this.y;
}

fn total(xs: i32[..]) -> i32 {
    var t = 0;
    for (x) in xs {
        t += x;
    }
    return t;
}

fn deep(p: point&, n: i32) -> i32 {
    if (n == 0) {
        return p.sum();
    }
    return deep(p, n - 1);
}

fn main() -> void {
    val p: point = { x: 2, y: 3 };
    val xs: i32[3] = { 1, 2, 3 };
    var q = p;
    q.x = 10;
    std::println("{} {} {} {}", p.sum(), total(xs[..]), deep(&p, 3), q.sum());
}
// expect: 5 6 5 13
