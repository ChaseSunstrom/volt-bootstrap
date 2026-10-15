// a method taking this by value, through a reference: on a copy (the original stays), and on a
// value with nothing to free (read through the reference, as any value is)
use std::io;

struct res {
    s: std::string;
}

attach fn consume(this: res) -> usize {
    return this.s.len();
}

struct pt {
    x: i32;
}

attach fn twice(this: pt) -> i32 {
    return this.x * 2;
}

fn f(r: res&, p: pt&) -> usize {
    return (copy *r).consume() + @cast<usize>(p.twice());
}

fn main() -> void {
    var x: res = { s: std::string::from("abc") };
    var p: pt = { x: 4 };
    std::println("{} {}", f(&x, &p), x.s);
}
// expect: 11 abc
// flags: --leak-check
