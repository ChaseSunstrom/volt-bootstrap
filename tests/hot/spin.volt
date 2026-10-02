use std::io;
// bolt hot's test program: nearly all of its time is in work's loop

fn work(n: i64) -> i64 {
    var s: i64 = 0;
    for (i) in 0..n {
        s = s ^ (i * 2654435761 % 1000003);
    }
    return s;
}

fn main() -> void {
    std::println("{}", work(100000000));
}
