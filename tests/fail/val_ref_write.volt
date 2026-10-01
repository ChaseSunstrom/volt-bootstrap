fn main() -> void {
    val x = 0;
    val r = &x;
    *r = 1;
}
// error: can't assign through this; it reaches a val (or a parameter without var)
