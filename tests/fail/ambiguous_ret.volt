<T: type> attach fn make(static this: T) -> T { return 0; }
<T: type> attach fn make(static this: T) -> T? { return null; }
fn main() -> void { val a = i32::make(); }
// error: ambiguous
