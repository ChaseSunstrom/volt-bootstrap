// a container given a new value inside a loop over its items (xs = ..., this.items = ..., and
// this.a = ... inside a loop over this.a.b) warns: the old items go while the loop goes on over
// them. A reference pointed elsewhere frees nothing; a sibling field or a field of plain data given
// a value leaves the container be; a loop over a copy, a range or an array (read through its place
// each round) isn't over the old storage; and a container reached through another name isn't followed
use std::io;
struct inner {
    b: std::vec<i32> = {};
    n: i32 = 0;
}
struct bag {
    items: std::vec<i32> = {};
    a: inner = {};
    other: std::vec<i32> = {};
}
attach fn reset(this: bag&) -> void {
    for (y) in this.items.items() {
        this.items = {};
    }
    for (y) in this.a.b.items() {
        this.a = {};
    }
    for (y) in this.a.b.items() {
        this.a.b = {};
    }
}
attach fn quiet(this: bag&) -> void {
    for (y) in this.items.items() {
        this.other = {};
        this.a.n = y;
    }
    val c = this.items.copy();
    for (y) in c.items() {
        this.items = {};
    }
    for (k) in 0..this.items.len {
        this.items = {};
    }
    val r = &this.items;
    for (y) in r.items() {
        this.items = {};
    }
}
fn main() -> void {
    var xs: std::vec<i32> = {};
    xs.push(1) catch @panic("out of memory");
    for (x) in xs.items() {
        xs = {};
    }
    var s = std::string::from("ab");
    for (c) in s.as_str() {
        s = std::string::from("cd");
    }
    // a reference pointed elsewhere frees nothing
    var ys: std::vec<i32> = {};
    var r = &xs;
    for (x) in r.items() {
        r = &ys;
    }
    // an array's loop reads its slots each round: a new value lands in them
    var names: std::string[2] = { std::string::from("a"), std::string::from("b") };
    for (n) in names {
        names = { std::string::from("c"), std::string::from("d") };
    }
    // a name bound into one (n&) too: it points at the slot, which holds the new value
    for (n&) in names {
        names = { std::string::from("e"), std::string::from("f") };
        std::println(n.as_str());
    }
    var g: bag = {};
    g.reset();
    g.quiet();
}
