// a global's initializer with ~ or ! over constants is a constant, not set by a constructor
// (tests/golden.rs global_fold_has_no_constructor checks the IR)
use std::io;

val ALL: u32 = ~@cast<u32>(0);
val LOW: u64 = ~0x0F;
val NO: bool = !true;
val MIXED: u8 = ~@cast<u8>(1) & 0x7F;
val NEG: i32 = -(~5);

fn main() -> i32 {
    std::println("{} {} {} {} {}", ALL, LOW, NO, MIXED, NEG);
    return 0;
}

// expect: 4294967295 18446744073709551600 false 126 6
