struct r { n: i32; }
attach fn delete(this: r&) -> void {}
fn main() -> void {
    val a: r = { n: 1 };
    val f = |move a| () { };
    val b = a;
}
// error: 'a' was moved earlier
