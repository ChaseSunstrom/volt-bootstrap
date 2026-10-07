// a fn(...) value borrows a closure kept in a variable, one that owns what it captured (move) too:
// the closure stays where it is, deleted with its variable
use std::io;

struct tally {
    n: i32;
}

attach fn delete(this: tally&) -> void {
    std::println("tally {} gone", this.n);
}

fn twice(f: fn(i32) -> i32, x: i32) -> i32 {
    return f(f(x));
}

fn main() -> void {
    val t: tally = { n: 3 };
    val c = |move t| (x: i32) -> i32 { return x * t.n; };
    val f: fn(i32) -> i32 = c;
    std::println("{} {}", f(2), twice(c, 1));
}
// expect: 6 9
// expect: tally 3 gone
