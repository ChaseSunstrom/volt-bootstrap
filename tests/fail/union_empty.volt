trait t_none { fn f(this) -> i32; }
fn main() -> void { var x: t_none[] = {}; }
// error: no type attaches t_none
