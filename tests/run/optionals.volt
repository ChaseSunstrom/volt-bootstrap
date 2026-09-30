use std::io;

fn find(xs: i32[..], want: i32) -> usize? {
    for (x, i) in xs {
        if (x == want) { return i; }
    }
    return null;
}

fn bump(var some_op: i32?) -> i32? {
    if (some_op) {
        some_op += 1;
    }
    return some_op;
}

error e { NOPE }
fn ok() -> e!void {}

fn main() -> void {
    val arr: i32[] = { 4, 8, 15 };
    std::println("{} {}", find(arr, 8), find(arr, 9));
    val idx = find(arr, 16) ?? 99;
    std::println(idx);
    std::println("{} {}", bump(41), bump(null));
    var x: i32? = 3;
    std::println("{} {} {}", x.value, x.none, x == null);
    var p: i32* = null;
    std::println(p == null);
    val r = ok();
    std::println("{} {}", r, r.err);
    var count = 0;
    var next: i32? = 3;
    while (next) {
        count += next;
        next = if_less(next);
    }
    std::println(count);
}

fn if_less(n: i32) -> i32? {
    if (n > 0) { return n - 1; }
    return null;
}
// expect: 1 null
// expect: 99
// expect: 42 null
// expect: 3 false false
// expect: true
// expect:  null
// expect: 6
