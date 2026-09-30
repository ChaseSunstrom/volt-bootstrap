// error: suspend only works inside an async fn
fn f() -> void { suspend; }
fn main() -> void { f(); }
