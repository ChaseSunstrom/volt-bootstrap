trait t_x { fn f(this) -> i32; }
<T: t_x> fn g(v: T) -> void {}
fn main() -> void { g(1); }
// error: T = i32 doesn't attach t_x
