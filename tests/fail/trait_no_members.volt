// a trait nothing attaches is a type with no values: a struct literal of it is refused (a fuzzed
// program once panicked the compiler at @typeid of such a type; trait_empty.volt still asks it)
trait thing { fn n(this) -> i32; }
fn main() -> void { val t: thing = {}; }
// error: no type attaches thing, so it has no values
