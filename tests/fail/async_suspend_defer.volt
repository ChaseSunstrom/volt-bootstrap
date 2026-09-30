// error: suspend can't be inside a defer
async fn f() -> void { defer { suspend; } }
fn main() -> void { f(); }
