struct r { x: i32; }
attach fn delete(this: r&) -> void {}
fn main() -> void {
    val a: r = { x: 1 };
    val b = a;
    val c = a;
}
// error: 'a' was moved earlier
