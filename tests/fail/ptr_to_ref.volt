fn f(r: i32&) -> void {}
fn main() -> void { val p: i32* = null; f(p); }
// error: argument 1 is a i32*, but 'f' wants a i32&
