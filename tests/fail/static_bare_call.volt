// a static fn is called through its type, counter::start(), not by its bare name (T-0631)
struct counter { n: i32; }
attach fn start(static this: counter) -> counter { return { n: 0 }; }
fn main() -> void { val c = start(); }
// error: start is a static fn: call it through its type, T::start(...)
