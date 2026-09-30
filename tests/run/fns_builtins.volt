use std::io;

fn scale(x: i32, by: i32 = 10) -> i32 { return x * by; }
fn apply(f: fn(i32) -> i32, v: i32) -> i32 { return f(v); }
fn inc(n: i32) -> i32 { return n + 1; }
export fn volt_add(a: i32, b: i32) -> i32 { return a + b; }

struct pair { a: u8; b: u64; }

fn main() -> void {
    std::println("{} {}", scale(4), scale(4, 3));
    std::println(apply(inc, 41));
    val f: fn(i32) -> i32 = inc;
    std::println(f(1));
    std::println(volt_add(2, 3));
    std::println("{} {}", @sizeof(pair), @alignof(u64));
    val big: i64 = 300;
    val low: u8 = @cast<u8>(big);
    std::println(low);
    var i = 0;
    while (i < 3) { i++; }
    std::println(i);
    var zero = 0;
    std::println(10 / zero);
}
// expect: 40 12
// expect: 42
// expect: 2
// expect: 5
// expect: 16 8
// expect: 44
// expect: 3
// exit: 101
