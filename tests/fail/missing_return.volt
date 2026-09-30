fn f(x: i32) -> i32 {
    if (x > 0) { return 1; }
}
fn main() -> void { f(1); }
// error: can reach its end without returning
