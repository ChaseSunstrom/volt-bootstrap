// send and sync, derived from what a type holds: a raw pointer is neither, a reference is send when
// what it points to is sync, a closure is what its captures are, a struct what its fields are;
// @send and @sync claim them for a type that guards its pointers, @not_send and @not_sync take them
// away. An unmet bound warns (the program still builds): std::thread::spawn's closure must be send
use std::io;
use std::thread;

struct plain {
    a: i32;
    s: str;
}

struct raw {
    p: i32*;
}

struct holds {
    r: raw;
}

@attributes([@send, @sync])
struct guarded {
    p: i32*;
}

@attributes([@not_send])
struct pinned {
    a: i32;
}

<T: send>
fn give(x: T) -> void {}

<T: sync>
fn share(x: T&) -> void {}

fn main() -> void {
    var n = 5;
    val p: plain = { a: 1, s: "x" };
    give(p);
    val r: raw = { p: &n };
    give(r);
    val h: holds = { r: { p: &n } };
    give(h);
    val g: guarded = { p: &n };
    give(g);
    val pin: pinned = { a: 2 };
    give(pin);
    share(&p);
    share(&r);
    val q: i32* = &n;
    val t1 = std::thread::spawn(|q| () { std::println("{}", *q); }) catch @panic("no thread");
    val t2 = std::thread::spawn(|n&| () { std::println("{}", n); }) catch @panic("no thread");
    val t3 = std::thread::spawn(|r&| () { std::println("{}", *r.p); }) catch @panic("no thread");
}
