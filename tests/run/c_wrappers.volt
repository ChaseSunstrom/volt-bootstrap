// C wrappers (long double and _Complex functions) whose C types Volt spells another way: a static
// function's long * and const char * arguments and result, a header's own cf64 next to Volt's
// complex struct (cf64_ then), a function bound to another symbol (glibc's __REDIRECT) and one
// declared only under a macro the program's C doesn't set (c_hidden.h; unused, so never called).
// Under C99 c_wrappers.h is a unit of its own, which the C compiler takes as strictly as it does by
// default (GCC 14 refuses a long long * for a long *). tests/run/c_wrappers_c.volt runs it through
// the C backend
use std::io;
@attributes([@standard("c99")])
use { "c_wrappers.h" } as m;
use { "c_hidden.h" } as plain;
use { "c_hidden_on.h" } as on;

fn main() -> void {
    var n: i64 = 40;
    val sum = m::ld_add(&n, "2");
    val p = m::ld_store(&n, 7.9);
    var w: cstr? = "5";
    std::println("{} {} {} {}", sum, n, *p, m::ld_first(&w));
    val mine: m::cf64 = { a: 1, b: 2 };
    val z = m::c_swap({ re: 1.0, im: 2.0 });
    std::println("{} {} {}", m::cf64_sum(mine), z.re, z.im);
    std::println("{} {} {}", m::ld_parse("2.5", null), plain::ld_shown(1.5), on::ld_shown(2.0));
}
// flags: --backend llvm
// expect: 42 7 7 5
// expect: 3 2 1
// expect: 2.5 2.5 3
