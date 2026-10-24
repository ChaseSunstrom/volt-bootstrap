// a named fn as a comptime parameter or a constant generic parameter: each fn its own instance
use std::io;

fn twice(comptime f: fn(i32) -> i32, x: i32) -> i32 { return f(f(x)); }

<F: extern "C" fn(i32) -> i32>
fn once(x: i32) -> i32 { return F(x); }

fn inc(x: i32) -> i32 { return x + 1; }
fn dbl(x: i32) -> i32 { return x * 2; }

fn main() -> void {
    std::println("{} {}", twice(inc, 5), twice(dbl, 5));
    std::println(once<dbl>(4));
    val g: extern "C" fn(i32) -> i32 = once<inc>;
    std::println(g(9));
}

// expect: 7 20
// expect: 8
// expect: 10
