// conversions that lose nothing happen by themselves: usize and u64 (isize and i64) are the same 64
// bits on every target, and a float holds every value of a small enough integer (f64 one of 32 bits,
// f32 one of 16); overloads still pick the exact type, and prefer integers to floats
use std::io;
fn half(x: f64) -> f64 {
    return x / 2.0;
}
fn next(n: u64) -> u64 {
    return n + 1;
}
fn which(n: u64) -> str {
    return "u64";
}
fn which(n: usize) -> str {
    return "usize";
}
fn kind(n: i64) -> str {
    return "integer";
}
fn kind(x: f64) -> str {
    return "float";
}
fn main() -> void {
    val xs: i32[3] = { 1, 2, 3 };
    val n = xs.len;
    val a: u64 = n;
    val b: usize = a;
    var i: isize = -4;
    val j: i64 = i;
    val k: isize = j;
    val c: i32 = 7;
    std::println("{} {} {} {} {}", a, b, k, half(c), next(xs.len));
    val small: u16 = 65535;
    val f: f32 = small;
    std::println("{} {}", f, c * 1.5);
    std::println("{} {}", which(a), which(b));
    // an integer overload beats a float one an i32 also fits
    std::println("{} {}", kind(c), kind(2.5));
}
// expect: 3 3 -4 3.5 4
// expect: 65535 10.5
// expect: u64 usize
// expect: integer float
