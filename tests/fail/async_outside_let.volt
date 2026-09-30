// error: only works as `val fr = async f()`
async fn g() -> i32 { return 1; }
fn take(x: i32) -> void {}
fn main() -> void { take(async g()); }
