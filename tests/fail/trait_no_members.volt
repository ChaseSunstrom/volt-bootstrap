// a trait nothing attaches can't be a type: said so, without crashing at @typeid after it (a fuzzed
// program panicked the compiler there)
trait thing { fn n(this) -> i32; }
fn make() -> thing { @panic("none"); }
fn main() -> void { val id = @typeid(make()); }
// error: no type attaches thing, so it can't be used as a type
