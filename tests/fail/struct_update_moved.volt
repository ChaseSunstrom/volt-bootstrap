// an owned base moves into the update, so it can't be used after
use std::io;
struct named { name: std::string; n: i32 = 0; }
fn main() -> void {
    val a: named = { name: std::string::from("a") };
    val b: named = { ..a, n: 1 };
    std::println("{}", a.n);
}
// error: 'a' was moved earlier
