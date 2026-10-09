// a { } literal passed straight to a comptime fn takes its type from the parameter (an array of
// struct literals too), and a struct's elements can be positional at compile time as at run time
use std::io;

struct acid {
    c: u8;
    p: f64;
}

comptime fn cumulative(xs: acid[3]) -> acid[3] {
    var out = xs;
    var sum = 0.0;
    for (i) in 0..3 {
        sum += out[i].p;
        out[i].p = sum;
    }
    return out;
}

comptime fn first_p(x: acid) -> f64 {
    return x.p;
}

val TABLE = cumulative({ { c: 'a', p: 0.5 }, { c: 'b', p: 0.25 }, { c: 'c', p: 0.25 } });
val ONE = first_p({ c: 'x', p: 0.125 });
val PAIRS: acid[2] = { { 'y', 0.5 }, { 'z', 0.25 } };
val SECOND = first_p(PAIRS[1]);

fn main() -> void {
    std::println("{} {} {}", TABLE[1].p, TABLE[2].p, TABLE[2].c);
    std::println("{} {}", ONE, SECOND);
}

// expect: 0.75 1 99
// expect: 0.125 0.25
