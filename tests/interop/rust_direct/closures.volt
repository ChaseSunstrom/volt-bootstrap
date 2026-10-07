use std::io;
// closures both ways: Volt's into Rust fns that take Fn, FnMut or Box<dyn Fn>; Rust's back as
// values Volt calls with call(...)
use { "geom" } as geom;

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
}
