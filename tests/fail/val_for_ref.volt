// (x&) over a val array points at what can't change
fn main() -> void {
    val a: i32[3] = { 1, 2, 3 };
    for (x&) in a {
        *x = 5;
    }
}
// error: can't assign through this; it reaches a val (or a parameter without var)
