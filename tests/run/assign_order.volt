use std::io;
// `place = value` evaluates the value first, then the place; `place += value` the place first
// (it reads the place). Both backends agree.

var log: i32 = 0;

fn f() -> usize {
    log = log * 10 + 1;
    return 0;
}

fn g() -> i32 {
    log = log * 10 + 2;
    return 5;
}

struct pair { a: i64; b: i64; c: i64; }

var src: pair = { a: 1, b: 2, c: 3 };

fn bump() -> usize {
    src.a = 100;
    return 0;
}

struct cell { x: i32; }
struct holder { r: cell&; }

var c1: cell = { x: 1 };
var c2: cell = { x: 2 };

attach fn swap_to_c2(this: holder&) -> i32 {
    this.r = &c2;
    return 99;
}

fn main() -> void {
    var a: i32[2];
    a[f()] = g();
    std::print("{} ", log);
    log = 0;
    a[f()] += g();
    std::println("{} {}", log, a[0]);
    var ps: pair[1];
    ps[bump()] = src;         // src is read before bump changes it
    std::println("{} {}", ps[0].a, src.a);
    var h: holder = { r: &c1 };
    h.r.x = h.swap_to_c2();   // the call runs first: h.r points at c2 by the store
    std::println("{} {}", c1.x, c2.x);
}
// expect: 21 12 10
// expect: 1 100
// expect: 1 99
