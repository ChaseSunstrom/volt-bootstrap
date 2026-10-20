// the borrow warnings: a closure capturing by reference, kept in a std::func, warns (the func may
// outlive what it points at); by copy or move it doesn't
use std::io;

fn counter(start: i32) -> std::func<fn() -> i32> {
    var n = start;
    return |n&| () { return n + 1; };
}

fn fine(start: i32) -> std::func<fn() -> i32> {
    return |start| () { return start + 1; };
}

fn main() -> void {
    val c = counter(1);
    val f = fine(2);
    std::println("{}", f());
}
