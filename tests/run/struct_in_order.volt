use std::io;
// a struct literal of a known type: fields by name, by a variable of the same name, or all in
// declaration order (the rest from their defaults); a local moves into a field without `move`
struct span { lo: u32; hi: u32; }
struct path {
    segs: std::vec<i32>;
    at: span;
    tag: u8 = 9;
}
enum kind {
    PATH: path,
    NONE,
}

fn main() -> void {
    var segs: std::vec<i32> = {};
    segs.push(4);
    segs.push(5);
    val at: span = { 3, 8 };
    val k = kind::PATH({ move segs, at });
    match (k) {
        .PATH(p) => { std::println("{} {} {} {}", p.segs.len, p.at.lo, p.at.hi, p.tag); },
        .NONE => {},
    }
    var more: std::vec<i32> = {};
    more.push(1);
    val q: path = { more, { 0, 2 }, 1 };
    std::println("{} {} {}", q.segs.len, q.at.hi, q.tag);
}
// expect: 2 3 8 9
// expect: 1 2 1
