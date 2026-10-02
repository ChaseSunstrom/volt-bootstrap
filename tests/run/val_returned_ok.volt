use std::io;
// Reading through a returned reference into a val is fine, and so is writing through one that
// points into a var (or into an argument the result doesn't come from).

fn id(r: i32&) -> i32& {
    return r;
}

fn second(a: i32&, b: i32&) -> i32& {
    return b;
}

fn deep(r: i32&) -> i32& {
    return id(r);
}

fn main() -> void {
    val a = 1;
    var b = 2;
    std::println("{}", *id(&a) + 1);
    *id(&b) = 5;
    *second(&a, &b) += 1;
    *deep(&b) += 10;
    var xs: std::vec<i32> = {};
    xs.push(1);
    val ys = copy xs;
    *xs.at(0) = 7;
    std::println("{} {} {} {}", a, b, *xs.at(0), *ys.at(0));
}
// expect: 2
// expect: 1 16 7 1
