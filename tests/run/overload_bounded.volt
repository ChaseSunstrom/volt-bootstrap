// Between generic versions that fit equally well, one whose type parameter has a trait bound is more
// specific than one taking any type: it wins for the types that attach the trait
use std::io;

trait marked {}

struct a {
    n: i32;
}

struct b {
    n: i32;
}

attach marked -> a {}

<T: type>
attach fn describe(this: T&) -> str {
    return "any";
}

<T: marked>
attach fn describe(this: T&) -> str {
    return "marked";
}

<T: type>
fn pick(v: T) -> str {
    return "any";
}

<T: marked>
fn pick(v: T) -> str {
    return "marked";
}

fn main() -> void {
    val x: a = { n: 1 };
    val y: b = { n: 2 };
    std::println("{} {}", x.describe(), y.describe());
    std::println("{} {} {}", pick(x), pick(y), pick(3));
}
// expect: marked any
// expect: marked any any
