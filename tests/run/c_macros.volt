// What has no type until it's used, called from Volt: a function-like macro gets a C function per
// call's argument types (its result the expression's type), a va_list function takes Volt's
// arguments as varargs, and a varargs function giving or taking a long double or _Complex is called
// per use too. printf and vsnprintf come from stdio.h. tests/run/c_macros_c.volt runs it through
// the C backend
use std::io;
use { "stdio.h" } as stdio;
use { "c_macros.h" } as m;

fn main() -> void {
    val a: i32 = 3;
    val b: i32 = 7;
    val x: f64 = 2.5;
    std::println("{} {} {} {}", m::MAX(a, b), m::MAX(x, 1.0), m::SQUARE(x), m::SQUARE(b));
    var p: m::pt = { x: 4, y: 5 };
    std::println("{} {} {}", m::PT_SUM(&p), m::BUMP(&p), p.x);
    std::println("{}", m::HALF_LD(b));
    var ps: m::pt[2] = { { x: 1, y: 2 }, { x: 3, y: 4 } };
    std::println("{}", m::FIRST_PT(&ps[0])->y);
    std::println("{} {}", m::vsum(3, 1, 2, 3), m::vsum(0));
    m::vscale(&p, 10, 1, 2);
    std::println("{} {}", p.x, p.y);
    std::println("{} {}", m::ldsum(2, 1.5, 2.0), m::ldcount(1.0, 5, 6, 7, 0));
    val z = m::cmake(2, 1.5, -2.0);
    std::println("{} {}", z.re, z.im);
    var n2: i32 = 1;
    val after = m::INC(n2);
    std::println("{} {} {} {}", after, n2, m::LEN("abc"), m::NAME_OF(5));
    val c: m::color = m::RED;
    val xp = m::X_OF(&p);
    var big: i64 = 7;
    std::println("{} {} {} {} {}", m::COLOR_AFTER(c), m::PT_TOTAL(p), *xp, m::FIRST_CHAR("hey"), m::READ_LONG(&big));
    stdio::printf("printf %d\n", 3);
    stdio::fflush(stdio::stdout);
    var buf: u8[32];
    val bp = @cast<cstr>(&buf[0]);
    val n = stdio::snprintf(bp, 32, "%d-%s", 7, "x");
    val k = vfmt(bp, 32, "%d+%d", 2, 40);
    std::println("{} {} {}", n, k, buf[2]);
}

fn vfmt(buf: cstr, cap: usize, f: cstr, a: i32, b: i32) -> i32 {
    return stdio::vsnprintf(buf, cap, f, a, b);
}
// expect: 7 2.5 6.25 49
// expect: 9 5 5
// expect: 3.5
// expect: 2
// expect: 6 0
// expect: 10 20
// expect: 3.5 4
// expect: 1.5 -2
// expect: 2 2 3 5
// expect: 5 30 10 104 7
// expect: printf 3
// expect: 3 4 52
