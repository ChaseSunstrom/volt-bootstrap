use std::io;
use { "stdlib.h" } as c;
// a Volt function C calls back: defined with the C ABI under its own C name
extern "C" fn by_value(a: void*, b: void*) -> i32 {
    val x = *@cast<i32*>(a);
    val y = *@cast<i32*>(b);
    return x - y;
}
fn main() -> void {
    var xs: i32[5] = { 5, 3, 9, 1, 4 };
    c::qsort(@cast<void*>(&xs[0]), 5, 4, by_value);
    std::println("{} {} {} {} {}", xs[0], xs[1], xs[2], xs[3], xs[4]);
}
// expect: 1 3 4 5 9
