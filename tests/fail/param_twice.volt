// two parameters can't share a name (the bindings gave each language a fn it couldn't compile)
fn pick(c: i32, d: i32, c: i64) -> i64 { return c; }
fn main() -> void { val x = pick(1, 2, 3); }
// error: 'c' is already a parameter of this fn
