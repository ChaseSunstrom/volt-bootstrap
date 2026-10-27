// integers of any width from 1 to 128 bits: u3, i7, u24, u48 and i100 hold, compute and print as their
// widths say, each in the next standard size; the wrapping ops wrap at the width, casts truncate or
// extend there, and a narrower one widens to a wider one as the standard integers do
use std::io;

struct rgb {
    r: u5;
    g: u6;
    b: u5;
}

fn main() -> void {
    val a: u3 = 5;
    val b: i7 = -64;
    val c: u24 = 16777215;
    val d: u48 = 281474976710655;
    val e: i100 = -633825300114114700748351602688;
    std::println("{} {} {} {} {}", a, b, c, d, e);
    std::println("{} {} {} {}", @sizeof(u3), @sizeof(u24), @sizeof(u48), @sizeof(i100));
    std::println("{} {} {}", c +% 1, b -% 1, a *% 3);
    std::println("{} {}", @cast<u3>(13), @cast<i7>(100));
    val wide: u32 = c;
    std::println("{}", wide + 1);
    val px: rgb = { r: 31, g: 63, b: 0 };
    std::println("{} {} {}", px.r, px.g, px.b);
    var sum: u24 = 0;
    for (i) in 0..10 {
        sum += @cast<u24>(i);
    }
    std::println("{} {}", sum, sum > 40);
    val one: u1 = 1;
    val neg: i1 = -1;
    std::println("{} {} {}", one, neg, @typeinfo(u24).short_name);
}
// expect: 5 -64 16777215 281474976710655 -633825300114114700748351602688
// expect: 1 4 8 16
// expect: 0 63 7
// expect: 5 -28
// expect: 16777216
// expect: 31 63 0
// expect: 45 true
// expect: 1 -1 u24
