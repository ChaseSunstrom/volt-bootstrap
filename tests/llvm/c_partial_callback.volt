use std::io;
// a Volt fn taking a C struct only C can pass by value, handed to C as a function pointer (C calls
// it): the program is built through C, with a note naming it
use { "../run/c_partial.h" } as c;
// expect-stderr: note: building through C: the fn 'twice' takes or gives
// expect-stderr: used as a function pointer
// expect-stderr: c_partial_callback.volt:

fn twice(p: c::pair) -> f32 {
    return c::pair_sum(p) * 2.0;
}

fn main() -> void {
    val p = c::pair_make(2.0);
    std::println("{}", c::pair_apply(twice, p));
}

// expect: 24
