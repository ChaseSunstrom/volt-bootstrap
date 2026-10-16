// u128 literals up to 2^128 - 1 (past i128's maximum), in every place a literal goes, folded at
// compile time with u128's unsigned semantics and run the same at run time (tests/golden.rs
// u128_literals_c runs it with the C backend too)
use std::io;

val MAX: u128 = 340282366920938463463374607431768211455;
val SIGN: u128 = 0x80000000000000000000000000000000;
val THIRD: u128 = MAX / 3;
val SEVENTH: u128 = MAX % 7;
val TOP: u128 = MAX >> 100;
val ABOVE: bool = SIGN > 1;
val HALVES: bool = MAX - SIGN == SIGN - 1;
val SUM: u128 = SIGN + 0x7FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF;

struct holder {
    v: u128;
}

fn with_default(x: u128 = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF) -> u128 {
    return x;
}

comptime fn ct_ops() -> u128 {
    val m: u128 = 340282366920938463463374607431768211455;
    return m / 5 + (m >> 127) + m % 10;
}

fn main() -> i32 {
    std::println("{} {}", MAX, SIGN);
    std::println("{} {} {} {} {} {}", THIRD, SEVENTH, TOP, ABOVE, HALVES, SUM);
    var local: u128 = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFE;
    local += 1;
    std::println("{} {}", local, local == MAX);
    std::println("{}", with_default());
    val h: holder = { v: 170141183460469231731687303715884105728 };
    std::println("{}", h.v == SIGN);
    val arr: u128[2] = { 340282366920938463463374607431768211455, 0x80000000000000000000000000000001 };
    std::println("{} {}", arr[0], arr[1]);
    // the literal takes the u128 side's type
    std::println("{} {} {}", MAX == 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF, SIGN != 340282366920938463463374607431768211455, SIGN < 340282366920938463463374607431768211455);
    comptime val c = ct_ops();
    std::println("{}", c);
    // the same at run time, from values the compiler can't see through
    var m = local;
    var s = h.v;
    std::println("{} {} {} {} {}", m / 3, m % 7, m >> 100, s > 1, m - s == s - 1);
    std::println("{}", m / 5 + (m >> 127) + m % 10);
    return 0;
}

// expect: 340282366920938463463374607431768211455 170141183460469231731687303715884105728
// expect: 113427455640312821154458202477256070485 3 268435455 true true 340282366920938463463374607431768211455
// expect: 340282366920938463463374607431768211455 true
// expect: 340282366920938463463374607431768211455
// expect: true
// expect: 340282366920938463463374607431768211455 170141183460469231731687303715884105729
// expect: true true true
// expect: 68056473384187692692674921486353642297
// expect: 113427455640312821154458202477256070485 3 268435455 true true
// expect: 68056473384187692692674921486353642297
