use std::io;
use std::compare;
// between generic versions that fit equally well, the more specific one wins: a generic type's own
// eq and cmp beat std::compare's blanket <T> ones, wherever std calls them

<T: type>
struct boxed { v: T; tag: str; }

// boxes compare by value only (their tag doesn't count); the blanket would compare with ==, which
// a struct doesn't have
<T: type>
attach fn eq(this: boxed<T>&, other: boxed<T>&) -> bool { return this.v == other.v; }
<T: type>
attach fn cmp(this: boxed<T>&, other: boxed<T>&) -> i32 { return this.v.cmp(&other.v); }

<T: type>
fn same(a: T&, b: T&) -> bool { return a.eq(b); }

fn main() -> void {
    val x: boxed<i32> = { v: 3, tag: "x" };
    val y: boxed<i32> = { v: 3, tag: "y" };
    var xs: boxed<i32>[] = { { v: 9, tag: "a" }, { v: 1, tag: "b" }, { v: 5, tag: "c" } };
    xs[..].sort();
    std::println("{} {} {}{}{}", x.eq(&y), same(&x, &y), xs[0].tag, xs[1].tag, xs[2].tag);
}
// expect: true true bca
