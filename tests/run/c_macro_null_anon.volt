// a bare null given to a function-like macro is C's NULL; a macro giving an anonymous struct gives a
// Volt struct with its fields, named for the macro (c_macro_null_anon.h)
use std::io;
use { "c_macro_null_anon.h" } as c;

fn main() -> void {
    var n: i32 = 7;
    val pn: i32* = &n;
    std::println("{} {} {}", c::FIRST(null), c::FIRST(pn), c::IS_NULL(null));
    val p = c::PAIR(1, 2);
    std::println("{} {}", p.x, p.y);
    val s = c::SPAN(3);
    std::println("{} {} {}", s.lo, s.hi, s.n);
}
// expect: -1 7 1
// expect: 1 2
// expect: 0.5 1.5 3
