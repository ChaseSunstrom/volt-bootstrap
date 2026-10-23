// built with --backtrace, a panic lists the calls that led to it after its own line, innermost
// first: each function, and where it was called from
// flags: --backtrace
use std::io;

fn inner(xs: i32[..], i: usize) -> i32 {
    return xs[i];
}

fn middle(xs: i32[..]) -> i32 {
    val n = inner(xs, 1);
    return inner(xs, 7) + n;
}

fn main() -> void {
    val a: i32[3] = { 1, 2, 3 };
    std::println("start");
    std::println("{}", middle(a[0..3]));
}
// expect: start
// exit: 101
// expect-stderr: backtrace.volt:7:12: panic: index 7 out of bounds (len 3)
// expect-stderr:   in inner, called from
// expect-stderr: backtrace.volt:12:12
// expect-stderr:   in middle, called from
// expect-stderr: backtrace.volt:18:24
// expect-stderr:   in main
