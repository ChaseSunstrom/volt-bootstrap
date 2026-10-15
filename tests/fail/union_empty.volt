// an implicit coercion into a trait nothing attaches: it has no values
trait unused { fn f(this) -> i32; }
fn main() -> void { var x: unused[] = { 1 }; }
// error: no type attaches unused, so it has no values
