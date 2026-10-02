use std::io;
// bolt hot's test program for a hot leaf: spin calls nothing, and nearly all of the time is in it.
// A sample there must still reach main through work, spin's caller, which takes a frame pointer in
// spin too (voltc builds --profiler programs with clang when it's there: gcc 16 leaves leaves out)

@attributes([@noinline])
fn spin(n: i64) -> i64 {
    var s: i64 = 0;
    for (i) in 0..n {
        s = (s ^ i) * 2654435761 % 1000003;
    }
    return s;
}

@attributes([@noinline])
fn work(n: i64) -> i64 {
    return spin(n) + spin(n / 2);
}

fn main() -> void {
    std::println("{}", work(60000000));
}
