// a static fn is named through its type as a value too, counter::start (T-0631)
struct counter { n: i32; }
attach fn start(static this: counter) -> counter { return { n: 0 }; }
fn main() -> void { val g = start; }
// error: start is a static fn: name it through its type, counter::start
