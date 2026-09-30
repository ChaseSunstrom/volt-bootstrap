// error: 'g' isn't an async fn
fn g() -> i32 { return 1; }
fn main() -> void { val x = await g(); }
