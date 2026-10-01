// fib: the naive doubly recursive Fibonacci, which is all function calls
use std::io;
use std::text;

fn fib(n: i32) -> i64 {
    if (n < 2) {
        return @cast<i64>(n);
    }
    return fib(n - 1) + fib(n - 2);
}

fn main() -> void {
    val n = @cast<i32>((std::process::arg(1) ?? "42").parse_int() catch 42);
    std::println(fib(n));
}
