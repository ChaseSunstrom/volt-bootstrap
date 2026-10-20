// error: suspend only works inside an async fn
fn f() -> void { defer { suspend; } }
fn main() -> void { f(); }
