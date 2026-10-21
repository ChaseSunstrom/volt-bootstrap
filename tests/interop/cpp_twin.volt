// a template pair f(T&) / f(T): f(&m) calls the reference one, f_value(5) the value one
use std::io;
use { "cpp_twin.hpp" } as cpp;

fn main() -> void {
    var m: i32 = 5;
    val r = cpp::tw::twin(&m);
    std::println("ref {} {}", r, m);
    std::println("value {}", cpp::tw::twin_value(5));
    val k: i32 = 3;
    std::println("peek {} {}", cpp::tw::peek(&k), cpp::tw::peek_value(4));
    val p: i32* = &m;
    std::println("deref {} {}", cpp::tw::deref(&p), cpp::tw::deref_value(p));
    var d: i32 = 1;
    val dr = cpp::tw::dflt(&d, 4);
    std::println("dflt {} {} {}", dr, d, cpp::tw::dflt_value_int(9, 2));
    var b: i32 = 2;
    val br = cpp::tw::Box::pair(&b);
    std::println("box {} {} {}", br, b, cpp::tw::Box::pair_value(3));
    var s: i32 = 1;
    val sr = cpp::tw::Box::twin(&s);
    std::println("static {} {} {} {}", sr, s, cpp::tw::solo(1), cpp::tw::Box::solo(1));
    var a = cpp::tw::Acc::new(7);
    var x: i32 = 1;
    val ar = a.add(&x);
    std::println("acc {} {} {}", ar, x, a.add_value(1));
    val g: i32 = 2;
    std::println("get {} {}", a.get(&g), a.get_value(2));
    var y: i32 = 1;
    val vr = a.vol(&y);
    std::println("vol {} {} {}", vr, y, a.vol_value(5));
}
// expect: ref 1 6
// expect: value 2
// expect: peek 13 24
// expect: deref 36 46
// expect: dflt 50 5 62
// expect: box 70 12 83
// expect: static 3 101 96 91
// expect: acc 100 8 208
// expect: get 309 409
// expect: vol 900 2 1005
