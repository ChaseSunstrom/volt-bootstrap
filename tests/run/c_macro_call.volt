use std::io;
// a #define that's a call of a header function reads as a value of its result type (Windows' stdio.h
// has #define stdout (__acrt_iob_func(1))): C expands the macro on each read
use { "c_macro_call.h" } as c;
fn bump(k: c::counter*) -> void {
    k->n += 1;
}
fn main() -> void {
    val a = c::first_counter;
    bump(c::first_counter);
    std::println("{} {} {}", a->n, c::third_counter->n, a == c::first_counter);
}
// expect: 11 30 true
