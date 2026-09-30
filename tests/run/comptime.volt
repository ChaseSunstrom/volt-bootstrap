use std::io;

comptime fn fib(n: i32) -> i64 {
    var a: i64 = 0;
    var b: i64 = 1;
    for (i) in 0..n {
        val t = a + b;
        a = b;
        b = t;
    }
    return a;
}

comptime fn pick_type(big: bool) -> type {
    if (big) { return i64; }
    return i8;
}

comptime fn squares() -> i32[5] {
    var out: i32[5] = { 0, 0, 0, 0, 0 };
    for (i) in 0..5 { out[i] = i * i; }
    return out;
}

<C: i32>
fn comp() -> i32 {
    comptime var determined_type: type;
    comptime if (C > 0) {
        determined_type = i32;
    } else {
        determined_type = i8;
    }
    var result: determined_type = 0;
    var i: determined_type = 0;
    while (i < 10) {
        result += i;
        i++;
    }
    return result as i32;
}

<C: i32>
fn classify() -> str {
    comptime match (C) {
        0 => { return "zero"; },
        c if c > 100 => { return "big"; },
        default => { return "other"; },
    }
}

struct point { x: i32; y: i64; z: u8; }

<T: type>
fn type_name(v: T) -> str { return @typeinfo(T).short_name; }

<Args: type...>
fn show(args: Args...) -> void {
    comptime for (arg) in args {
        std::print(arg);
        std::print(" ");
    }
    std::println();
}

val TABLE_LEN: usize = fib(10);

fn main() -> void {
    val f = fib(50);
    std::println(f);
    val x: pick_type(true) = 5000000000;
    std::println(x);
    std::println(squares());
    std::println("{} {}", comp<1>(), comp<0>());
    std::println("{} {} {}", classify<0>(), classify<500>(), classify<7>());
    std::println("{} {} {}", @sizeof(point), @typeinfo(point).size.value, type_name(1.5));
    std::println(@typeinfo(std::mem::box<i32>).canonical_name);
    show(1, "two", 3.5, true);
    var arr: u8[TABLE_LEN];
    std::println(arr.len);
    comptime for (i) in 0..3 {
        std::print(i);
    }
    std::println();
}
// expect: 12586269025
// expect: 5000000000
// expect: { 0, 1, 4, 9, 16 }
// expect: 45 45
// expect: zero big other
// expect: 24 24 f64
// expect: std::mem::box<i32, std::mem::default_allocator>
// expect: 1 two 3.5 true 
// expect: 55
// expect: 012
