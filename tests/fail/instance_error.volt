<T: type> fn f(x: T) -> T { return x.nope; }
fn main() -> void { f(1); }
// error: f<i32> is instantiated here
