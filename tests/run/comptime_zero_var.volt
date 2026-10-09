// a var without an initializer starts at zero at compile time too, as at run time: a big array, a
// struct, a number, a bool and an optional, read before anything is written to them
use std::io;

struct pt {
    x: i32;
    y: i32;
}

comptime fn bit_counts() -> u8[512] {
    var bits: u8[512];
    for (i) in 1..512 {
        bits[i] = bits[i / 2] + @cast<u8>(i % 2);
    }
    return bits;
}

comptime fn zeros() -> i32 {
    var p: pt;
    var n: i32;
    var b: bool;
    var o: i32?;
    if (b || o != null) {
        return -1;
    }
    p.y += 2;
    return p.x + p.y + n;
}

val BITS = bit_counts();
val Z = zeros();

fn main() -> void {
    std::println("{} {} {} {}", BITS[0], BITS[7], BITS[511], Z);
}

// expect: 0 3 9 2
