// @cast<void*>(f) on a function's name is the C function's address (T-0140): it casts back to its
// extern "C" fn type, and C code given it (qsort's comparator) calls it directly
use std::io;

extern "C" fn abs(x: i32) -> i32;
extern "C" fn qsort(base: void*, n: usize, size: usize, cmp: void*) -> void;

export fn by_value(a: void*, b: void*) -> i32 {
    return *@cast<i32*>(a) - *@cast<i32*>(b);
}

fn main() -> void {
    val p = @cast<void*>(abs);
    val f = @cast<extern "C" fn(i32) -> i32>(p);
    std::println("{}", f(-5));
    var xs: i32[4] = { 3, 1, 4, 1 };
    qsort(@cast<void*>(&xs[0]), 4, 4, @cast<void*>(by_value));
    std::println("{} {} {} {}", xs[0], xs[1], xs[2], xs[3]);
    std::println("{}", @cast<void*>(by_value) == @cast<void*>(by_value));
}
// expect: 5
// expect: 1 1 3 4
// expect: true
