// @unchecked: no bounds checks in the function's body, for a hot loop known to stay in range. Here
// the index goes past the slice into the array behind it, which a checked read would stop at
use std::io;
@attributes([@unchecked])
fn get(xs: i32[..], i: usize) -> i32 {
    return xs[i];
}
fn main() -> void {
    val a: i32[8] = { 10, 11, 12, 13, 14, 15, 16, 17 };
    std::println(get(a[0..4], 6));
}
// expect: 16
