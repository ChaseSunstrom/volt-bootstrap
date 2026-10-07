// long double and _Complex through C wrappers: a long double is an f64, a double _Complex a cf64
// { re, im } (float's a cf32); a named C enum is a Volt enum that reads, prints and passes as its
// integer, as C's does (an anonymous one stays i32 constants). tests/run/c_more_types_c.volt runs
// it through the C backend
use std::io;
use { "stdlib.h" } as libc;
use { "c_more_types.h" } as m;

fn main() -> void {
    std::println("{} {} {}", m::ld_half(5.0), m::ld_scale(1.5, 4, null), libc::strtold("2.25", null));
    val z = m::c_mul({ re: 1.0, im: 2.0 }, { re: 3.0, im: 4.0 });
    val w: m::cf32 = m::cf_twice({ re: 1.5, im: -0.5 });
    val s = m::cl_swap({ re: 1.0, im: 2.0 });
    std::println("{} {} {} {} {} {} {}", z.re, z.im, m::c_norm(z), w.re, w.im, s.re, s.im);
    val a: m::axis = m::axis_next(m::AXIS_X);
    match (a) {
        .AXIS_Y => { std::println("next is y"); },
        default => { std::println("next isn't y"); },
    }
    var i: i32 = 0;
    m::axis_last(&i);
    std::println("{} {} {} {} {}", a, a as i32, i, m::axis_rank(m::AXIS_Z), m::axis_rank(1));
    std::println("{} {} {} {}", m::AXIS_Y | m::AXIS_Z, m::MODE_DEFAULT == m::MODE_ON, m::mode_flip(m::MODE_OFF), m::ANON_LIMIT + 1);
    // its number to compound assignment, indexing, ranges, array lengths and @cast; an unsigned's
    // address passes for a pointer to one too (C's enums are int or unsigned int)
    var k = m::AXIS_X;
    k += 1;
    k |= 4;
    k++;
    k <<= 1;
    var flags: i32 = 0;
    flags |= m::AXIS_Z;
    var u: u32 = 0;
    m::axis_last(&u);
    val names: str[m::AXIS_Z + 1] = { "x", "y", "-", "-", "z" };
    var steps = 0;
    for (x) in m::AXIS_X..m::AXIS_Z {
        steps += x;
    }
    val wide: i64 = m::AXIS_Z;
    std::println("{} {} {} {} {} {} {} {}", k, flags, u, names[m::AXIS_Z], names[a], names.len, steps, wide + @cast<i64>(m::AXIS_Y));
    // a complex field is C's to read and write (a struct of its own to Volt only by value)
    var p: m::sample = { along: m::AXIS_Y };
    m::sample_set(&p, { re: 0.5, im: 2.0 });
    std::println("{} {}", m::sample_sum(&p), p.along == m::AXIS_Y);
}
// flags: --backend llvm
// expect: 2.5 7 2.25
// expect: -5 10 125 3 -1 2 1
// expect: next is y
// expect: 1 1 4 3 2
// expect: 5 true 1 10
// expect: 12 4 4 z y 5 6 5
// expect: 3.5 true
