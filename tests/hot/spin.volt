use std::io;
// bolt hot's test program: nearly all of its time is in work's loop, much of it in mix, which is
// always inlined. work is kept out of line (gcc makes it a copy, work.constprop.0, for its constant
// argument) and prints, so it isn't a leaf: gcc gives leaves no frame pointer

@attributes([@inline])
fn mix(i: i64) -> i64 {
    return i * 2654435761 % 1000003;
}

@attributes([@noinline])
fn work(n: i64) -> void {
    var s: i64 = 0;
    for (i) in 0..n {
        s = s ^ mix(i);
    }
    std::println("{}", s);
}

fn main() -> void {
    work(100000000);
}
