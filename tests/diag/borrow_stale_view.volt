// the borrow warnings: a view into a container (items(), as_str()) used after a call that may move
// or free the container's items (push, append, clear) warns, and the program still builds; a view
// got again after the change, a copy, and a value popped off don't
use std::io;
fn len_after_push(xs: std::vec<i32>&) -> usize {
    val s = xs.items();
    xs.push(4) catch @panic("out of memory");
    return s.len;
}
fn main() -> void {
    var xs: std::vec<i32> = {};
    xs.push(1) catch @panic("out of memory");
    val s = xs.items();
    xs.push(2) catch @panic("out of memory");
    std::println(s.len);
    val t = xs.items();
    std::println(t.len);
    val c = xs.copy();
    xs.clear();
    std::println(c.len);
    var ys: std::vec<i32> = {};
    ys.push(1) catch @panic("out of memory");
    for (y) in ys.items() {
        ys.push(y) catch @panic("out of memory");
    }
    var zs: std::vec<i32> = {};
    zs.push(1) catch @panic("out of memory");
    val first = zs.items();
    for (k) in 0..3 {
        std::println(first.len);
        zs.push(k) catch @panic("out of memory");
    }
    var name = std::string::from("ab");
    val n = name.as_str();
    name.append("cd");
    std::println(n.len);
    std::println(len_after_push(&xs));
    // a value a method gives back, as pop's, is no view, whatever it holds
    var names: std::vec<str> = {};
    names.push("a") catch @panic("out of memory");
    val last = names.pop();
    names.push("b") catch @panic("out of memory");
    if (last) {
        std::println(last);
    }
}
