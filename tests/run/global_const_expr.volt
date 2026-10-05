// a global's initializer can be any constant expression, worked out at compile time: arithmetic and
// bit operations over literals and other val globals, inside literals too
use std::io;

val FLAG: u32 = 1 << 13;
val MASK: u32 = FLAG | 0x10;
val MIXED: i64 = -(3 * 4) + 100 / 7;
var LOW: u32 = (FLAG >> 2) & 0xFF;
val TABLE: u32[3] = { 1 << 2, FLAG, 7 % 3 };

fn main() -> void {
    std::println("{} {} {} {}", FLAG, MASK, MIXED, LOW);
    LOW += 1;
    std::println("{} {} {} {}", TABLE[0], TABLE[1], TABLE[2], LOW);
}
// expect: 8192 8208 2 0
// expect: 4 8192 1 1
