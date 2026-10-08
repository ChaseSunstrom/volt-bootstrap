use std::io;
use std::fmt;
// closures both ways: Volt's into Rust fns that take Fn, FnMut or Box<dyn Fn>; Rust's back as
// values Volt calls with call(...)
use { "geom" } as geom;

// counts the probes dropped: one a closure Rust keeps holds is dropped once, when Rust drops it
var dropped = 0;

struct probe {
    n: i32;
}

attach fn delete(this: probe&) -> void {
    dropped += 1;
}

fn main() -> void {
    val k = 3;
    val xs: i32[4] = { 1, 4, 2, 6 };
    std::println("apply {} count {} boxed {}", geom::apply(|k| (x: i32) -> i32 { return x * k; }, 5), geom::count_with(xs[..], |k| (x: i32) -> bool { return x > k; }), geom::call_boxed(|k| (x: i32) -> i32 { return x + k; }));
    geom::each_word("rust calls volt", || (w: str) -> void { std::print("[{}]", w); });
    std::println("");
    val add2 = geom::adder(2);
    var c = geom::counter();
    c.call();
    val first = geom::initial_of("volt");
    std::println("adder {} counter {} initial {}", add2.call(40), c.call(), first.call());
    val ws: str[2] = { "a", "b" };
    val hi = geom::greeter("hi");
    {
        var p: probe = { n: 3 };
        val twice = geom::keep_boxed(|move p| (x: i32) -> i32 { return x + p.n; });
        std::println("kept {} dropped {}", twice.call(1), dropped);
    }
    std::println("dropped {}", dropped);
    std::println("{} / {}", geom::mark_each(ws[..], || (w: str) -> std::string { return std::fmt::format("<{}>", w); }), hi.call("volt"));
}
