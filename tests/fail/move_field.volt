struct r { x: i32; }
attach fn delete(this: r&) -> void {}
struct w { inner: r; }
fn main() -> void {
    val a: w = { inner: { x: 1 } };
    val b = a.inner;
}
// error: can't move a r out of a field
