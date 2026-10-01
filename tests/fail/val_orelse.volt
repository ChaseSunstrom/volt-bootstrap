// a reference from ?? is read-only when either side is
fn main() -> void {
    val x = 0;
    val p: i32* = null;
    val q = p ?? &x;
    *q = 1;
}
// error: can't assign through this; it reaches a val (or a parameter without var)
