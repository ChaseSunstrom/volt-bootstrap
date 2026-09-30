// error: can't cast .BOOL to an integer
comptime fn f() -> i32 {
    return @cast<i32>(@typeinfo(bool).kind);
}
val K: i32 = f();
use std::io;
fn main() -> void { std::println(K); }
