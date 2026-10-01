// two generic versions just as specific as each other: still ambiguous
<T: type>
struct pair { a: T; }
<T: type>
attach fn show(this: pair<T>&, x: i32) -> i32 { return 1; }
<U: type>
attach fn show(this: pair<U>&, x: i32) -> i32 { return 2; }
fn main() -> void {
    val p: pair<i32> = { a: 1 };
    val n = p.show(3);
}
// error: ambiguous
