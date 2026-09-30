error e1 { X }
error e2 { Y }
fn g() -> e1!i32 { return 1; }
fn h() -> e2!i32 { return try g(); }
fn main() -> void { h(); }
// error: this can fail with e1, but the function returns e2 errors
