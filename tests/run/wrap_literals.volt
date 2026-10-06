// a wrapping operator on two literals wraps in the type its value gets, and stays exact until it gets
// one (fuzzed programs had 134 *% 115 refused next to a u8, 4000000000 +% 4000000000 as a u32, and
// (0 -% 15) & m as not fitting m's u32)
use std::io;
fn main() -> void {
    val a: u32 = 4000000000 +% 4000000000;
    val b: u8 = 134 *% 115;
    val c: u64 = 0 -% 1;
    val d: i8 = 100 +% 100;
    var h: u8 = 7;
    var m: u32 = 0xFF;
    var big: u64 = 18446744073709551600;
    val e = 2000000000 +% 2000000000;
    val f: u128 = 0 -% 1;
    var g: u128 = 0;
    var small: u8 = 0;
    std::println("{} {} {} {} {}", a, b, c, d, h ^ (134 *% 115));
    std::println("{} {} {}", (0 -% 15) & m, (0 -% 16) == big, e);
    std::println("{} {} {}", f, g | (0 -% 1), small < ((3 -% 10) | 5));
}
// expect: 3705032704 50 18446744073709551615 -56 53
// expect: 241 true 4000000000
// expect: 340282366920938463463374607431768211455 340282366920938463463374607431768211455 true
