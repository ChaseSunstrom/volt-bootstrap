struct r { x: i32; }
attach fn delete(this: r&) -> void {}
fn eat(v: r) -> void {}
fn main() -> void {
    val a: r = { x: 1 };
    for (i) in 0..3 { eat(a); }
}
// error: 'a' is moved inside a loop and has no new value before the next pass
