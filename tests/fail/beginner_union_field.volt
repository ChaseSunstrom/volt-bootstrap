// a field of an error union's value, taken without unwrapping it: try or catch first
use std::io;
fn main() -> void {
    val t = std::fs::read_file("x");
    std::println("{}", t.len);
}
// error: has no field 'len'
// error: it's an error union: unwrap it with try (or catch) first, then use its value
