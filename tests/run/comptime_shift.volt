// shifts at compile time agree with run time: the left literal takes the wanted type (a comptime fn's
// return type, an annotation, a parameter's type, a global's declared type), the amount any integer
// type; a global shifted by a constant global (through another) folds
use std::io;

comptime fn mask(k: u32) -> u64 {
    return 1 << k;
}
comptime fn inner(k: u8) -> u64 {
    val x: u64 = 1 << k;
    return x + 1;
}
comptime fn take(v: u64) -> u64 {
    return v;
}
comptime fn arg(k: u32) -> u64 {
    return take(1 << k);
}
comptime fn sum(k: i64) -> u64 {
    return (1 << k) + 1;
}
comptime fn neg(k: u32) -> i64 {
    val m: i64 = -256;
    return m >> k;
}
fn rt_mask(k: u32) -> u64 {
    return 1 << k;
}

val K32: u32 = 40;
val M: u64 = 1 << K32;
val A: u32 = K32;
val CH: u64 = 1 << A;
val ARR: i32[mask(3)] = {};

fn main() -> void {
    std::println("{} {}", mask(35), rt_mask(35));
    std::println("{} {} {} {}", inner(40), arg(33), sum(34), neg(4));
    std::println("{} {} {}", M, CH, ARR.len);
}
// expect: 34359738368 34359738368
// expect: 1099511627777 8589934592 17179869185 -16
// expect: 1099511627776 1099511627776 8
