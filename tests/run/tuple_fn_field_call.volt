use std::io;
// a call on a tuple's numbered (or named) field holding a fn calls the field, like a struct's fn field

fn twice(n: i32) -> i32 { return n * 2; }

extern "C" fn neg(n: i32) -> i32 { return -n; }

fn through(p: (fn(i32) -> i32, i32)&) -> i32 { return p.0(p.1); }

fn main() -> void {
    val k = 100;
    val t = (twice, |k| (a: i32) -> i32 { return a + k; });
    std::println("{} {}", t.0(4), t.1(5));
    val f: (fn(i32) -> i32, extern "C" fn(i32) -> i32) = (twice, neg);
    std::println("{} {}", f.0(6), f.1(7));
    val n: (dbl: fn(i32) -> i32, n: i32) = (twice, 3);
    std::println("{}", n.dbl(n.n));
    val r: (fn(i32) -> i32, i32) = (twice, 21);
    std::println("{}", through(&r));
}
// expect: 8 105
// expect: 12 -7
// expect: 6
// expect: 42
