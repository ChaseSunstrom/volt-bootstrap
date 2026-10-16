// a global's initializer with ~ or ! over constants is a constant, not set by a constructor
// (tests/golden.rs global_fold_has_no_constructor checks the IR)
use std::io;

val ALL: u32 = ~@cast<u32>(0);
val LOW: u64 = ~0x0F;
val NO: bool = !true;
val MIXED: u8 = ~@cast<u8>(1) & 0x7F;
val NEG: i32 = -(~5);
// a slice global over an array global stays a view of it (folding would make a temporary array)
val TABLE: i32[3] = { 1, 2, 3 };
val SL: i32[..] = TABLE;

fn main() -> i32 {
    std::println("{} {} {} {} {}", ALL, LOW, NO, MIXED, NEG);
    std::println("{} {}", SL.len, SL[2]);
    return 0;
}

// expect: 4294967295 18446744073709551600 false 126 6
// expect: 3 3
