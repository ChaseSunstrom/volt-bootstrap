struct r { x: i32; }
attach fn delete(this: r&) -> void {}
fn main() -> void {
    var a: r = { x: 1 };
    a.delete();
}
// error: delete runs by itself
