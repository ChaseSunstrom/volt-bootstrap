use std::io;
// a val is shallow: what its slices and pointers point at isn't part of it. And read-only fn values
// and closures can be given references to vals
struct holder {
    p: i32*;
}

fn set(s: i32[..]) -> void {
    s[0] = 9;
}

fn poke(h: holder&) -> void {
    *h.p = 5;
}

fn peek(r: i32&) -> i32 {
    return *r;
}

fn call(f: fn(i32&) -> i32, r: i32&) -> i32 {
    return f(r);
}

fn main() -> void {
    var a: i32[3] = { 1, 2, 3 };
    val s = a[0..2];
    set(s);
    for (x&) in s {
        *x += 1;
    }
    var n = 1;
    val h: holder = { p: &n };
    poke(&h);
    val k = 4;
    val twice = || (r: i32&) -> i32 { return *r * 2; };
    std::println("{} {} {} {} {} {}", a[0], a[1], n, call(peek, &k), twice(&k), call(twice, &k));
    // a val slice of a var array sorts it; a var slice of a val array can be reseated
    var nums: i32[3] = { 3, 1, 2 };
    val all = nums[..];
    all.sort();
    val fixed: i32[3] = { 9, 8, 7 };
    var rest = fixed[..];
    rest = rest[1..];
    std::println("{} {} {} {}", nums[0], nums[2], rest.len, rest.contains(7));
}
// expect: 10 3 5 4 8 8
// expect: 1 3 2 true
