// fib: the naive doubly recursive Fibonacci, which is all function calls
fn fib(n: i32) -> i64 {
    if n < 2 { n as i64 } else { fib(n - 1) + fib(n - 2) }
}

fn main() {
    let n = std::env::args().nth(1).and_then(|a| a.parse().ok()).unwrap_or(42);
    println!("{}", fib(n));
}
