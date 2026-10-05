// struct update literals: { ..base, a: x } is base with the named fields replaced; an owned base
// moves and a plain one copies, as `var t = base;` would, and a replaced owned field is deleted
use std::io;

struct window {
    title: str;
    width: i32 = 800;
    height: i32 = 600;
}

struct loud {
    name: str;
}

attach fn delete(this: loud&) -> void {
    std::println("delete {}", this.name);
}

struct pair {
    a: loud;
    b: loud;
    n: i32 = 0;
}

// through a reference (this, a T& parameter) base is the value it reaches: the update never
// writes through it; an owned one is copied with ..copy
attach fn moved(this: window&, dx: i32) -> window {
    return { ..this, width: this.width + dx };
}

struct named {
    name: std::string;
    n: i32 = 0;
}

attach fn renumbered(this: named&, n: i32) -> named {
    return { ..copy this, n };
}

fn width_of(w: window) -> i32 {
    return w.width;
}

fn wider(w: window) -> window {
    return { ..w, width: w.width * 2 };
}

comptime val BASE: window = { title: "base" };
comptime val TALL: window = { ..BASE, height: 900 };

comptime fn square(w: window) -> window {
    return { ..w, height: w.width };
}

fn maybe(w: window) -> window? {
    return { ..w, title: "maybe" };
}

fn main() -> void {
    // a plain base is copied: w is still there
    val w: window = { title: "editor", width: 1024 };
    val v: window = { ..w, title: "shell" };
    std::println("{} {} {}", w.title, v.title, v.width);
    // the type comes from base when nothing else gives one; shorthand names work too
    val height = 300;
    val s = { ..w, height };
    std::println(s);
    // as an argument, and in a function's return
    std::println("{} {}", width_of({ ..w, width: 5 }), wider(w).width);
    // nothing replaced: a copy
    val same: window = { ..w };
    std::println(same.height);
    // comptime
    comptime val sq = square(BASE);
    std::println("{} {} {}", TALL.title, TALL.height, sq.height);
    // field values read base itself, not the copy being filled in
    val turned: window = { ..w, width: w.height, height: w.width };
    std::println("{} {} {}", turned.width, turned.height, (maybe(w) ?? w).title);
    // through references
    var m: window = { title: "m" };
    val r = &m;
    val viaref = { ..r, height: 1 };
    val nm: named = { name: std::string::from("nm") };
    std::println("{} {} {} {} {}", m.height, viaref.height, m.moved(10).width, nm.renumbered(3).n, nm.name.as_str());
    // an owned base moves; the replaced field's old value is deleted, once
    var p: pair = { a: { name: "a1" }, b: { name: "b1" } };
    std::println("update");
    val q: pair = { ..p, b: { name: "b2" }, n: 7 };
    std::println("updated {} {} {}", q.a.name, q.b.name, q.n);
}
// expect: editor shell 1024
// expect: window { title: editor, width: 1024, height: 300 }
// expect: 5 2048
// expect: 600
// expect: base 900 800
// expect: 600 1024 maybe
// expect: 600 1 810 3 nm
// expect: update
// expect: delete b1
// expect: updated a1 b2 7
// expect: delete b2
// expect: delete a1
