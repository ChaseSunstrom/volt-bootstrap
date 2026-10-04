trait fx { fn f(this) -> i32; }
<T: fx> fn g(v: T) -> void {}
fn main() -> void { g(1); }
// error: T = i32 doesn't attach fx
