// the borrow warnings follow a container given a new value (xs = ys, this.items = ..., *this = ...):
// its views look into what's gone; a field of the container given a value (xs.n = ...) leaves them be
use std::io;
struct bag {
    items: std::vec<i32> = {};
    n: i32 = 0;
}
attach fn reset(this: bag&) -> usize {
    val s = this.items.items();
    this.items = {};
    return s.len;
}
attach fn replace(this: bag&, other: bag) -> usize {
    val s = this.items.items();
    *this = other;
    return s.len;
}
attach fn count(this: bag&) -> usize {
    val s = this.items.items();
    this.n = 2;
    return s.len;
}
fn main() -> void {
    var xs: std::vec<i32> = {};
    var ys: std::vec<i32> = {};
    xs.push(1) catch @panic("out of memory");
    val s = xs.items();
    xs = ys;
    std::println(s.len);
    var zs: std::vec<i32> = {};
    val first = zs.items();
    for (k) in 0..3 {
        std::println(first.len);
        zs = {};
    }
    var g: bag = {};
    std::println(g.reset());
    std::println(g.replace({}));
    std::println(g.count());
}
