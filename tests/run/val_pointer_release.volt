// a val pointer global is a constant pointer, not a pointer to constants: what it points to can be
// written, release builds included (T-0172: the bootstrap's C made the target const)
// flags: --release
use std::io;

var counter: i32 = 0;
val counter_at: i32* = &counter;
var total: i64 = 40;
val total_at: i64* = &total;

fn main() -> void {
    *counter_at = 5;
    *total_at += 2;
    std::println("{} {}", counter, total);
}
// expect: 5 42
