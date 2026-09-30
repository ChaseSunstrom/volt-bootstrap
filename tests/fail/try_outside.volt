error e { X }
fn g() -> e!i32 { return 1; }
fn main() -> void { val x = try g(); }
// error: try only works inside a function that returns an error union
