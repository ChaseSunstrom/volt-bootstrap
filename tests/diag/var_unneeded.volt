// var on a parameter the fn never changes is a warning; changing it in any way (assigning, taking its
// address, calling a method that changes it, capturing it by reference) needs the var
use std::io;

struct counter {
    n: i32 = 0;
}

attach fn bump(this: counter&) -> void {
    this.n += 1;
}

fn set(r: i32&) -> void {
    *r = 1;
}

fn assigned(var a: i32) -> i32 {
    a += 1;
    return a;
}

fn lent(var b: i32) -> i32 {
    set(&b);
    return b;
}

fn method(var c: counter) -> i32 {
    c.bump();
    return c.n;
}

fn captured(var d: i32) -> i32 {
    val f = |d&| () { d = 5; };
    f();
    return d;
}

fn unchanged(var e: i32, var r: i32&) -> i32 {
    *r = e;
    return e + 1;
}

fn test_ref(var mut: i32&) -> void {
    *mut + 1;
}

fn main() -> void {
    var x = 0;
    test_ref(&x);
    val c: counter = {};
    std::println("{} {} {} {} {}", assigned(1), lent(2), method(c), captured(3), unchanged(4, &x));
}
