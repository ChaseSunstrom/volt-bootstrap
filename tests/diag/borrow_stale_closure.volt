// the borrow warnings follow closures held in a local and called by its name: one using a view warns
// when called after the view's container changed; one changing a captured container is that change
// where it's called; a closure passed away isn't followed
use std::io;
<F: type>
fn run(f: F) -> void { f(); }
fn main() -> void {
    var xs: std::vec<i32> = {};
    xs.push(1) catch @panic("out of memory");
    val s = xs.items();
    val f = |s| () -> usize { return s.len; };
    xs.push(2) catch @panic("out of memory");
    std::println(f());
    var ys: std::vec<i32> = {};
    val grow = |ys&| () { ys.push(1) catch @panic("out of memory"); };
    val t = ys.items();
    grow();
    std::println(t.len);
    var zs: std::vec<i32> = {};
    val add = |zs&| () { zs.push(1) catch @panic("out of memory"); };
    val u = zs.items();
    run(add);
    std::println(u.len);
    var ws: std::vec<i32> = {};
    val w = ws.items();
    val g = |w&| () -> usize { return w.len; };
    for (k) in 0..3 {
        std::println(g());
        ws.push(k) catch @panic("out of memory");
    }
    var vs: std::vec<i32> = {};
    val more = |vs&| () { vs = {}; };
    val v = vs.items();
    for (k) in 0..3 {
        std::println(v.len);
        more();
    }
}
