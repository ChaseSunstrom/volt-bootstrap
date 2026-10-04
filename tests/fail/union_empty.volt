trait unused { fn f(this) -> i32; }
fn main() -> void { var x: unused[] = {}; }
// error: no type attaches unused
