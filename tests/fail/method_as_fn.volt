// a method called as a plain function, with nothing else by that name
struct box { n: i32; }
attach fn get(this: box&) -> i32 { return this.n; }
fn main() -> void { val b: box = { n: 1 }; val x = get(&b); }
// error: 'get' is a method; call it as x.get()
