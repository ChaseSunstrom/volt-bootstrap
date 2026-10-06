// @unchecked on an async fn: its body (built as the fn's step function) has no bounds checks either
use std::io;
@attributes([@unchecked])
async fn get(xs: i32[..], i: usize) -> i32 {
    return xs[i];
}
fn main() -> void {
    val a: i32[8] = { 10, 11, 12, 13, 14, 15, 16, 17 };
    var fr = async get(a[0..4], 6);
    std::println(await fr);
}
// expect: 16
