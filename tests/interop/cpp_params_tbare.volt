// a class template's T& takes a Volt reference: an i32 passed without & (C++'s write would be lost)
// is an error naming the parameter, laid out and held by handle (worked out per use)
use std::io;
use { "params.hpp" } as cpp;
fn main() -> void {
    var k: cpp::pr::ct::keep<i32> = { v: 3 };
    var n: i32 = 1;
    k.bump(n);
    std::println("{}", n);
}
fn held(h: cpp::pr::ct::held<i32>&, n: i32) -> void {
    h.bump(n);
}
