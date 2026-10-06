// error: else |e| needs an error union, found i32?
use std::io;
fn main() -> void {
    val opt: i32? = null;
    val v = if (val x = opt) x else |e| 0;
    std::println(v);
}
