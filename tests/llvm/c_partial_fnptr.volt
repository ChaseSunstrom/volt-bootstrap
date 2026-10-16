use std::io;
// a call through a C function pointer passing a C struct only C can pass by value: the program is
// built through C, with a note naming the call
use { "../run/c_partial.h" } as c;
// expect-stderr: note: building through C: a call through a C function pointer passes
// expect-stderr: c_partial_fnptr.volt:13

fn main() -> void {
    val p = c::pair_make(2.0);
    val f = c::pair_summer() ?? return;
    std::println("{}", c::pair_sum(p));
    // the pointer is C's: C passes p in floating-point registers
    val s = f(p);
    std::println("{}", s);
}

// expect: 12
// expect: 12
