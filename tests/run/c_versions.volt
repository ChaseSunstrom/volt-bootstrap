// headers written for different C standards in one program, each read and compiled under its own:
// the C89 one under C89 (its K&R definitions and bool typedef aren't C23, or C with <stdbool.h>) and
// the C99 one under C99, each in a unit of its own; C11's under the newest the compiler accepts, as
// is C23's (under --cc -std=gnu17, in a unit of its own too: tests/interop.rs)
use std::io;
@attributes([@standard("c89")])
use { "c89.h" } as old;
@attributes([@standard("c99")])
use { "c99.h" } as c99;
use { "c11.h" } as c11;
@attributes([@standard("c23")])
use { "c23.h" } as c23;

fn main() -> void {
    std::println("{} {} {}", old::kr_add(2, 3), old::is_even(4), old::kr_mix(1, 2.5));
    val a: i32[] = { 1, 2, 3 };
    val b: i32[] = { 4, 5, 6 };
    std::println("{} {}", c99::dot3(&a[0], &b[0]), c99::c99_flag());
    var s: c11::aligned16 = {};
    s.v = 1;
    s.lo = 2;
    s.hi = 7;
    std::println("{}", c11::c11_span(s));
    std::println("{} {} {} {}", c23::c23_limit, c23::c23_twice(21), c23::c23_ok(), c23::c23_none() == null);
}
// expect: 5 1 3.5
// expect: 32 true
// expect: 6
// expect: 10 42 true true
