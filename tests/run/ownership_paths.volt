use std::io;
struct r { n: i32; }
attach fn delete(this: r&) -> void { std::println("del {}", this.n); }
attach fn eat(this: r) -> i32 { return this.n; }

enum holder { ONE: r, NONE }

error e { BAD }

fn mk(n: i32) -> r { return { n: n }; }

fn early(flag: bool) -> i32 {
    val a = mk(1);
    {
        val b = mk(2);
        if (flag) { return 10; }
    }
    return 20;
}

fn fails(flag: bool) -> e!r {
    val a = mk(3);
    errdefer std::println("errdefer");
    if (flag) { return e::BAD; }
    return move a;
}

fn main() -> void {
    std::println(early(true));
    std::println(early(false));
    for (i) in 0..3 {
        val t = mk(10 + i);
        if (i == 1) { break; }
    }
    val x = fails(true) catch mk(99);
    val y = fails(false) catch mk(98);
    std::println(mk(5).eat());
    match (holder::ONE(mk(7))) {
        .ONE(v) => std::println("one {}", v.n),
        .NONE => {},
    }
    val maybe: r? = mk(8);
    if (maybe) { std::println("has {}", maybe.n); }
    std::println("end");
}
// expect: del 2
// expect: del 1
// expect: 10
// expect: del 2
// expect: del 1
// expect: 20
// expect: del 10
// expect: del 11
// expect: errdefer
// expect: del 3
// expect: del 5
// expect: 5
// expect: one 7
// expect: del 7
// expect: has 8
// expect: end
// expect: del 8
// expect: del 3
// expect: del 99
