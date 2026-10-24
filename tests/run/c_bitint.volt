// a C _BitInt(N) member is the smallest Volt integer of N bits or more (c_bitint.h): unsigned
// _BitInt(24) a u32, _BitInt(12) an i16 (a value has to fit N bits: C keeps no more)
// (clang's: gcc before 14, Linux's cc on CI, has no _BitInt)
// os: macos windows
use std::io;
use { "c_bitint.h" } as c;

fn main() -> void {
    var b: c::bits = {};
    b.u24 = 70000;
    b.s12 = -5;
    b.after = 1;
    std::println("{} {} {}", b.u24, b.s12, c::bits_sum(&b));
}
// expect: 70000 -5 69996
