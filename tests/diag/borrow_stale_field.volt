// the borrow warnings follow a field's container: a view of this.items goes stale when this.items
// may move or free its items; a change to another field (this.b) leaves a view of this.a alone
use std::io;
struct bag {
    items: std::vec<i32> = {};
    a: std::vec<i32> = {};
    b: std::vec<i32> = {};
}
attach fn grow(this: bag&) -> usize {
    val s = this.items.items();
    this.items.push(1) catch @panic("out of memory");
    return s.len;
}
attach fn other_field(this: bag&) -> usize {
    val s = this.a.items();
    this.b.push(1) catch @panic("out of memory");
    return s.len;
}
attach fn grow_in_loop(this: bag&) -> void {
    val first = this.items.items();
    for (k) in 0..3 {
        std::println(first.len);
        this.items.push(k) catch @panic("out of memory");
    }
}
fn main() -> void {
    var g: bag = {};
    std::println(g.grow());
    std::println(g.other_field());
    g.grow_in_loop();
    val s = g.items.items();
    g.items.clear();
    std::println(s.len);
}
